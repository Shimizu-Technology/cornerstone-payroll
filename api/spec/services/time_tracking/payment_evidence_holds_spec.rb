# frozen_string_literal: true

require "rails_helper"
RSpec.describe TimeTracking::PaymentEvidenceHolds do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:period) { create(:pay_period, company: company) }
  let(:employee) { create(:employee, company: company) }
  let(:uuid) { SecureRandom.uuid }
  let!(:mapping) { TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
    employee: employee, source_user_id: "91", source_user_uuid: uuid) }
  let(:client) { instance_double(TimeTracking::Client) }
  subject(:service) { described_class.new(pay_period: period, source: source, client: client) }
  let(:entry) { { "id" => "41", "version" => 2, "work_date" => period.start_date.iso8601,
    "employee" => { "id" => "91", "payroll_integration_id" => uuid } } }
  let(:hold) { { "id" => "501", "version" => 3, "source_user_uuid" => uuid,
    "source_time_entry_id" => "41", "work_date" => period.start_date.iso8601, "status" => "pending_evidence" } }
  let(:reason) { "Owner reported payment; actual check and delivery evidence is pending" }
  let(:command_id) { SecureRandom.uuid }
  def create_hold
    service.create!(source_time_entry_id: "41", source_user_uuid: uuid, expected_version: 2, command_id: command_id, reason: reason)
  end
  before do
    allow(client).to receive(:payroll_cockpit_time_entry).with(entry_id: "41").and_return("time_entry" => entry)
    allow(client).to receive(:payroll_payment_attestations).with(source_user_uuid: uuid, page: 1)
      .and_return("payment_attestations" => [ hold ], "pagination" => { "total_pages" => 1 })
  end
  it "delegates exact identity/version without creating payroll payments" do
    expect(client).to receive(:create_payroll_payment_attestation).with(source_time_entry_id: "41", source_user_uuid: uuid,
      expected_version: 2, command_id: command_id, reason: reason).and_return("payment_attestation" => hold)
    expect { create_hold }.not_to change(PayrollItem, :count)
  end
  it "rejects another company identity before accessing AIRE" do
    expect(client).not_to receive(:payroll_cockpit_time_entry)
    expect { service.create!(source_time_entry_id: "41", source_user_uuid: SecureRandom.uuid,
      expected_version: 2, command_id: command_id, reason: reason) }.to raise_error(TimeTracking::Client::Error, /permanent AIRE identity/)
  end
  it "rejects changed numeric identity or work date" do
    expect(client).not_to receive(:create_payroll_payment_attestation)
    entry["employee"]["id"] = "92"
    expect { create_hold }.to raise_error(TimeTracking::Client::Error, /identity or work date changed/)
    entry["employee"]["id"] = "91"; entry["work_date"] = (period.start_date - 1).iso8601
    expect { create_hold }.to raise_error(TimeTracking::Client::Error, /identity or work date changed/)
  end
  it "surfaces a remote version conflict" do
    allow(client).to receive(:create_payroll_payment_attestation).and_raise(TimeTracking::Client::Error.new("Source version changed", response_status: 409))
    expect { create_hold }.to raise_error(TimeTracking::Client::Error) { |error| expect(error.response_status).to eq(409) }
  end
  it "allows reasoned source-changed retraction and old-version command replay" do
    hold["source_changed"] = true; hold["version"] = 4
    expect(client).not_to receive(:payroll_cockpit_time_entry)
    expect(client).to receive(:retract_payroll_payment_attestation).with(attestation_id: "501", command_id: command_id,
      expected_version: 3, reason: reason).and_return("payment_attestation" => hold)
    service.retract!(attestation_id: "501", source_user_uuid: uuid, expected_version: 3, command_id: command_id, reason: reason)
  end
  it "rejects another period's hold and incomplete reasons" do
    hold["work_date"] = (period.start_date - 1).iso8601
    expect(client).not_to receive(:retract_payroll_payment_attestation)
    expect { service.retract!(attestation_id: "501", source_user_uuid: uuid, expected_version: 3,
      command_id: command_id, reason: reason) }.to raise_error(TimeTracking::Client::Error, /different work period/)
    expect { service.retract!(attestation_id: "501", source_user_uuid: uuid, expected_version: 3,
      command_id: command_id, reason: "paid") }.to raise_error(ArgumentError, /20 characters/)
  end
  it "retrieves later pages of evidence" do
    allow(client).to receive(:payroll_payment_attestations).with(source_user_uuid: uuid, page: 1)
      .and_return("payment_attestations" => [], "pagination" => { "total_pages" => 2 })
    allow(client).to receive(:payroll_payment_attestations).with(source_user_uuid: uuid, page: 2)
      .and_return("payment_attestations" => [ hold ], "pagination" => { "total_pages" => 2 })
    expect(client).to receive(:retract_payroll_payment_attestation).and_return("payment_attestation" => hold)
    service.retract!(attestation_id: "501", source_user_uuid: uuid, expected_version: 3, command_id: command_id, reason: reason)
  end
  it "offers only mapped positive nominal-period versioned hours" do
    row = { "source_time_entry_id" => "42", "source_kind" => "current", "source_time_entry_version" => 2, "original_work_date" => period.start_date.iso8601, "total_hours" => 4 }
    allow(client).to receive(:payroll_cockpit_manual_review).and_return("employees" => [
      { "source_user_uuid" => uuid, "adjustments" => [ row, row.merge("source_time_entry_id" => "41"), row.merge("source_kind" => "correction"), row.merge("total_hours" => -4), row.merge("source_time_entry_version" => nil),
        row.merge("original_work_date" => (period.start_date - 1).iso8601) ] },
      { "source_user_uuid" => SecureRandom.uuid, "adjustments" => [ row ] }
    ], "payment_attestations" => [ hold.merge("original_work_date" => hold["work_date"]) ])
    expect(service.review[:candidates]).to eq([ row.except("source_kind").merge("source_user_uuid" => uuid, "employee_name" => employee.full_name) ])
    expect(service.review[:payment_attestations]).to eq([ hold ])
  end
  it "fails explicitly when evidence history exceeds the bounded ten pages" do
    allow(client).to receive(:payroll_payment_attestations).and_return(
      "payment_attestations" => [], "pagination" => { "total_pages" => 11 })
    expect { service.retract!(attestation_id: "501", source_user_uuid: uuid, expected_version: 3,
      command_id: command_id, reason: reason) }.to raise_error(TimeTracking::Client::Error, /too large/)
    expect(client).to have_received(:payroll_payment_attestations).exactly(10).times
  end
end
