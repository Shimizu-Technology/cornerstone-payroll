# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeHoursEvidence do
  let(:employee) { create(:employee) }
  let(:actor) { create(:user, company: employee.company) }
  let(:connector) { double("Connector", authorization_origins: [ "https://time.example.com" ], employee_evidence_path: nil) }
  let(:source) { double("Source", id: 5, name: "Other business", last_synced_at: nil, active?: true, remote_identity_pinned?: true, supports?: true, connector: connector, expected_source_instance_id: "7944ba1c-f8f2-4ef1-a4bf-edf1b23d245c") }
  let(:mapping) { double("Mapping", time_tracking_source: source, time_tracking_source_id: 5, source_user_id: "42", source_user_uuid: "7f8a1940-a73f-4499-9506-aed78b9be5ea") }
  let(:client) { double("Client", payroll_employee_periods: { "periods" => [], "totals" => { "worked_hours" => 82 }, "pagination" => { "total_count" => 0 } }) }

  before do
    relation = double("Mapped employee relation")
    allow(TimeTrackingEmployeeMapping).to receive(:where).with(company_id: employee.company_id, employee_id: employee.id).and_return(relation)
    allow(relation).to receive_message_chain(:joins, :where, :includes, :order, :to_a).and_return([ mapping ])
    allow(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: actor).and_return(client)
  end

  it "passes the exact mapped permanent identity and cursor filter without assuming an AIRE source" do
    result = described_class.new(employee: employee, actor: actor, params: { start_date: "2026-08-01", cursor: "signed", per_page: 1 }).call
    expect(result[:status]).to eq("available")
    expect(client).to have_received(:payroll_employee_periods).with(employee_id: "42", source_user_uuid: mapping.source_user_uuid,
      start_date: "2026-08-01", end_date: nil, cursor: "signed", per_page: 1)
    expect(result[:source_workspace_url]).to be_nil
    expect(result.dig(:evidence, "totals", "worked_hours")).to eq(82)
  end

  it "builds only a trusted approved-origin route with both permanent employee and installation identity" do
    allow(connector).to receive(:employee_evidence_path).with(employee_id: "42", period_id: nil, entry_id: nil)
      .and_return("/admin/users/42?tab=hours")
    url = URI(described_class.new(employee: employee, actor: actor).call[:source_workspace_url])
    expect(url.host).to eq("time.example.com")
    expect(URI.decode_www_form(url.query).to_h).to include("source_user_uuid" => mapping.source_user_uuid,
      "source_instance_id" => source.expected_source_instance_id)
    allow(connector).to receive(:employee_evidence_path).and_return("//evil.example.com/users/42")
    expect(described_class.new(employee: employee, actor: actor).call[:source_workspace_url]).to be_nil
  end

  it "retains connection metadata without contacting a disabled source" do
    allow(source).to receive(:active?).and_return(false)
    result = described_class.new(employee: employee, actor: actor).call
    expect(result).to include(status: "unavailable", source_id: 5)
    expect(result[:sources]).to include(include(name: "Other business", active: false))
    expect(TimeTracking::Client).not_to have_received(:for_payroll_actor)
  end

  it "requires capability and stable identity before contacting the source" do
    allow(source).to receive(:supports?).with(:employee_period_evidence_v1).and_return(false)
    expect(described_class.new(employee: employee, actor: actor).call[:status]).to eq("unsupported")
    allow(source).to receive(:supports?).and_return(true)
    allow(mapping).to receive(:source_user_uuid).and_return(nil)
    expect(described_class.new(employee: employee, actor: actor).call[:status]).to eq("unavailable")
    expect(TimeTracking::Client).not_to have_received(:for_payroll_actor)
  end

  it "does not substitute another connection for an explicitly selected unmapped source" do
    expect { described_class.new(employee: employee, actor: actor, params: { source_id: 99 }).call }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "returns a retryable outage without erasing mapped source metadata" do
    allow(TimeTracking::Client).to receive(:for_payroll_actor).and_raise(TimeTracking::Client::Error, "Timeout")
    result = described_class.new(employee: employee, actor: actor).call
    expect(result).to include(status: "unavailable", source_id: 5, message: "Timeout")
  end

  it "links only exact payroll item and period pairs belonging to this employee and company" do
    period = create(:pay_period, :committed, company: employee.company)
    item = create(:payroll_item, :printed, pay_period: period, employee: employee)
    other = create(:payroll_item, pay_period: period, employee: create(:employee, company: employee.company))
    allow(client).to receive(:payroll_employee_period).and_return({ "period" => { "id" => "2026-08-01", "summary" => {}, "settlement_cases" => [], "entries" => [], "coverage_lines" => [
      { "external_payroll_item_id" => item.id.to_s, "external_pay_period_id" => period.id.to_s },
      { "external_payroll_item_id" => other.id.to_s, "external_pay_period_id" => period.id.to_s },
      { "external_payroll_item_id" => item.id.to_s, "external_pay_period_id" => "999" }
    ] } })
    result = described_class.new(employee: employee, actor: actor, params: { period_id: "2026-08-01" }).call
    expect(result[:payroll_records].map { |row| row[:payroll_item_id] }).to eq([ item.id ])
    expect(result[:payroll_records].first.dig(:payment_evidence, :status)).to eq("printed")
  end

  it "does not label a malformed successful source response as zero work" do
    allow(client).to receive(:payroll_employee_periods).and_return({ "periods" => [] })
    expect(described_class.new(employee: employee, actor: actor).call).to include(status: "unavailable",
      message: "The source returned incomplete employee period evidence. Please retry.")
  end

  it "rejects invalid filters before making a source request" do
    [ { start_date: "2026-02-30" }, { per_page: 101 }, { start_date: "2026-10-01", end_date: "2026-09-30" } ].each do |params|
      expect { described_class.new(employee: employee, actor: actor, params: params).call }.to raise_error(ArgumentError)
    end
    expect(TimeTracking::Client).not_to have_received(:for_payroll_actor)
  end
end
