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
    expect(service.review[:payment_attestations]).to eq([ hold.merge("employee_name" => employee.full_name) ])
  end
  it "requests only immutable work-period history from an explicitly verified resolution producer" do
    source.update!(expected_source_instance_id: SecureRandom.uuid, identity_verified_at: Time.current,
      source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ "payment_attestation_resolution_v1" ])
    allow(client).to receive(:payroll_cockpit_manual_review).and_return("employees" => [], "payment_attestations" => [])
    expect(client).to receive(:payroll_payment_attestations).with(page: 1,
      start_date: period.start_date.iso8601, end_date: period.end_date.iso8601)
      .and_return("payment_attestations" => [ hold ], "pagination" => { "total_pages" => 1 })
    expect(service.review[:payment_attestations].first["id"]).to eq(hold["id"])
  end

  it "reads a verified period once for many mapped workers and retains a held-only worker" do
    source.update!(expected_source_instance_id: SecureRandom.uuid, identity_verified_at: Time.current,
      source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ "payment_attestation_resolution_v1" ])
    12.times do |index|
      TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
        employee: create(:employee, company: company), source_user_id: "extra-#{index}", source_user_uuid: SecureRandom.uuid)
    end
    allow(client).to receive(:payroll_cockpit_manual_review).and_return("employees" => [], "exclusions" => [], "payment_attestations" => [])
    expect(client).to receive(:payroll_payment_attestations).once.with(page: 1,
      start_date: period.start_date.iso8601, end_date: period.end_date.iso8601)
      .and_return("payment_attestations" => [ hold, hold.merge("source_user_uuid" => SecureRandom.uuid) ], "pagination" => { "total_pages" => 1 })
    expect(service.review[:payment_attestations]).to eq([ hold.merge("employee_name" => employee.full_name) ])
  end

  it "loads later pages once each across workers and excludes out-of-period records" do
    source.update!(expected_source_instance_id: SecureRandom.uuid, identity_verified_at: Time.current,
      source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ "payment_attestation_resolution_v1" ])
    allow(client).to receive(:payroll_cockpit_manual_review).and_return("employees" => [])
    expect(client).to receive(:payroll_payment_attestations).with(page: 1, start_date: period.start_date.iso8601, end_date: period.end_date.iso8601)
      .and_return("payment_attestations" => [ hold.merge("work_date" => (period.start_date - 1).iso8601) ], "pagination" => { "total_pages" => 2 })
    expect(client).to receive(:payroll_payment_attestations).with(page: 2, start_date: period.start_date.iso8601, end_date: period.end_date.iso8601)
      .and_return("payment_attestations" => [ hold ], "pagination" => { "total_pages" => 2 })
    expect(service.review[:payment_attestations].map { |row| row["id"] }).to eq([ "501" ])
  end

  it "ignores mismatched employee holds without hiding that employee's available hours" do
    row = { "source_time_entry_id" => "42", "source_kind" => "current", "source_time_entry_version" => 2,
      "original_work_date" => period.start_date.iso8601, "total_hours" => 4 }
    allow(client).to receive(:payroll_cockpit_manual_review).and_return("employees" => [
      { "source_user_uuid" => uuid, "adjustments" => [ row ] }
    ])
    other_hold = hold.merge("source_user_uuid" => SecureRandom.uuid, "source_time_entry_id" => "42")
    allow(client).to receive(:payroll_payment_attestations).and_return("payment_attestations" => [
      hold, other_hold, other_hold.except("source_user_uuid")
    ], "pagination" => { "total_pages" => 1 })

    review = service.review
    expect(review[:payment_attestations]).to eq([ hold.merge("employee_name" => employee.full_name) ])
    expect(review[:candidates]).to eq([ row.except("source_kind").merge("source_user_uuid" => uuid,
      "employee_name" => employee.full_name) ])
  end

  it "fails explicitly when evidence history exceeds the bounded ten pages" do
    allow(client).to receive(:payroll_payment_attestations).and_return(
      "payment_attestations" => [], "pagination" => { "total_pages" => 11 })
    expect { service.retract!(attestation_id: "501", source_user_uuid: uuid, expected_version: 3,
      command_id: command_id, reason: reason) }.to raise_error(TimeTracking::Client::Error, /too large/)
    expect(client).to have_received(:payroll_payment_attestations).exactly(10).times
  end
  describe "bounded modern period fallback" do
    before do
      source.update!(expected_source_instance_id: SecureRandom.uuid, identity_verified_at: Time.current,
        source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
        source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ "payment_attestation_resolution_v1" ])
      allow(client).to receive(:payroll_cockpit_manual_review).and_return("employees" => [])
    end

    def modern_query(**attributes)
      { start_date: period.start_date.iso8601, end_date: period.end_date.iso8601, **attributes }
    end

    def overflow
      { "payment_attestations" => [ hold.merge("id" => "discard-bulk") ], "pagination" => { "total_pages" => 11 } }
    end

    it "abandons bulk evidence and retrieves thirteen mappings including held-only and later pages" do
      uuids = 12.times.map do |index|
        TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
          employee: create(:employee, company: company), source_user_id: "fallback-#{index}", source_user_uuid: SecureRandom.uuid).source_user_uuid
      end
      expect(client).to receive(:payroll_payment_attestations).with(**modern_query(page: 1)).once.and_return(overflow)
      ([ uuid ] + uuids).each do |worker_uuid|
        pages = worker_uuid == uuid ? 2 : 1
        rows = worker_uuid == uuid ? [ hold.merge("source_user_uuid" => SecureRandom.uuid), hold.merge("work_date" => (period.start_date - 1).iso8601) ] : []
        expect(client).to receive(:payroll_payment_attestations).with(**modern_query(source_user_uuid: worker_uuid, page: 1))
          .and_return("payment_attestations" => rows, "pagination" => { "total_pages" => pages })
      end
      expect(client).to receive(:payroll_payment_attestations).with(**modern_query(source_user_uuid: uuid, page: 2))
        .and_return("payment_attestations" => [ hold ], "pagination" => { "total_pages" => 2 })
      expect(service.review[:payment_attestations]).to eq([ hold.merge("employee_name" => employee.full_name) ])
    end

    it "refuses oversized scope before fanout without publishing partial evidence" do
      20.times do |index|
        TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
          employee: create(:employee, company: company), source_user_id: "oversize-#{index}", source_user_uuid: SecureRandom.uuid)
      end
      expect(client).to receive(:payroll_payment_attestations).with(**modern_query(page: 1)).once.and_return(overflow)
      expect { service.review }.to raise_error(TimeTracking::Client::Error, /request budget/)
      expect(service.instance_variable_get(:@attestations)).to eq({})
    end

    it "enforces the global budget when each worker is within ten pages" do
      TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
        employee: create(:employee, company: company), source_user_id: "budget-worker", source_user_uuid: SecureRandom.uuid)
      calls = 0
      allow(client).to receive(:payroll_payment_attestations) do |**query|
        calls += 1
        query[:source_user_uuid] ? { "payment_attestations" => [], "pagination" => { "total_pages" => 10 } } : overflow
      end
      expect { service.review }.to raise_error(TimeTracking::Client::Error, /request budget/)
      expect(calls).to eq(20)
      expect(service.instance_variable_get(:@attestations)).to eq({})
    end

    it "keeps the per-worker cap and discards exhausted fallback evidence" do
      allow(client).to receive(:payroll_payment_attestations).and_return(overflow)
      expect { service.review }.to raise_error(TimeTracking::Client::Error, /too large/)
      expect(client).to have_received(:payroll_payment_attestations).exactly(11).times
      expect(service.instance_variable_get(:@attestations)).to eq({})
    end

    it "enforces the elapsed deadline and starts a later retry without partial cache" do
      now = 100.0
      timed = described_class.new(pay_period: period, source: source, client: client, monotonic_clock: -> { now })
      allow(client).to receive(:payroll_payment_attestations) do |**_query|
        now += 31
        overflow
      end
      expect { timed.review }.to raise_error(TimeTracking::Client::Error, /timed out/)
      expect(timed.instance_variable_get(:@attestations)).to eq({})
      allow(client).to receive(:payroll_payment_attestations).with(**modern_query(page: 1))
        .and_return("payment_attestations" => [ hold ], "pagination" => { "total_pages" => 1 })
      expect(timed.review[:payment_attestations].map { |row| row["id"] }).to eq([ "501" ])
    end

    it "does not fall back on contract or malformed/changing pagination failures" do
      allow(client).to receive(:payroll_payment_attestations).and_raise(TimeTracking::Client::Error, "Installation descriptor changed")
      expect { service.review }.to raise_error(TimeTracking::Client::Error, /descriptor changed/)
      expect(client).to have_received(:payroll_payment_attestations).once
      allow(client).to receive(:payroll_payment_attestations).and_return("payment_attestations" => [], "pagination" => { "total_pages" => 11.5 })
      expect { service.review }.to raise_error(TimeTracking::Client::Error, /pagination/)
      allow(client).to receive(:payroll_payment_attestations).with(**modern_query(page: 1))
        .and_return("payment_attestations" => [ hold ], "pagination" => { "total_pages" => 2 })
      allow(client).to receive(:payroll_payment_attestations).with(**modern_query(page: 2))
        .and_return("payment_attestations" => [], "pagination" => { "total_pages" => 3 })
      expect { service.review }.to raise_error(TimeTracking::Client::Error, /pagination changed/)
      expect(service.instance_variable_get(:@attestations)).to eq({})
    end
  end
end
