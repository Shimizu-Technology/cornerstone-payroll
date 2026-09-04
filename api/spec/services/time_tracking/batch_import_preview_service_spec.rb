# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::BatchImportPreviewService do
  def finalized_payload(start_date:, end_date:, batch_id: "AIRE-PAY-TEST-001", employees: nil, exclusions: [])
    employees ||= [
      {
        "source_user_id" => "aire-user-1",
        "email" => "pilot@example.com",
        "display_name" => "Pilot One",
        "adjustments" => [
          {
            "source_time_entry_id" => "101",
            "line_key" => "flight:2500",
            "source_kind" => "current",
            "original_work_date" => start_date.iso8601,
            "original_week_start" => start_date.beginning_of_week(:sunday).iso8601,
            "source_category_id" => "flight",
            "category" => { "id" => "flight", "key" => "flight_hours", "name" => "Flight Hours" },
            "total_hours" => 8.0,
            "regular_hours" => 8.0,
            "overtime_hours" => 0.0
          }
        ],
        "total_hours" => 8.0,
        "regular_hours" => 8.0,
        "overtime_hours" => 0.0
      }
    ]
    adjustments = employees.flat_map { |employee| employee.fetch("adjustments") }
    payload = {
      "schema_version" => "2.0",
      "source" => "aire_services",
      "batch_id" => batch_id,
      "start_date" => start_date.iso8601,
      "end_date" => end_date.iso8601,
      "cutoff_at" => "2026-08-31T01:00:00Z",
      "generated_at" => "2026-08-31T01:00:00Z",
      "employees" => employees,
      "exclusions" => exclusions,
      "issues" => {
        "missing_category_count" => 0,
        "negative_adjustment_count" => adjustments.count { |adjustment| adjustment.values_at("regular_hours", "overtime_hours").any?(&:negative?) },
        "pending_approval_count" => exclusions.count { |row| row["reason"].in?(%w[pending_approval approved_after_cutoff created_after_cutoff]) },
        "denied_approval_count" => exclusions.count { |row| row["reason"] == "denied_approval" },
        "open_clock_count" => exclusions.count { |row| row["reason"] == "open_clock" },
        "pending_overtime_count" => exclusions.count { |row| row["reason"].in?(%w[pending_overtime overtime_approved_after_cutoff]) },
        "denied_overtime_count" => exclusions.count { |row| row["reason"] == "denied_overtime" }
      },
      "summary" => {
        "employee_count" => employees.size,
        "adjustment_count" => adjustments.size,
        "exclusion_count" => exclusions.size,
        "total_hours" => adjustments.sum { |row| row.fetch("total_hours") },
        "regular_hours" => adjustments.sum { |row| row.fetch("regular_hours") },
        "overtime_hours" => adjustments.sum { |row| row.fetch("overtime_hours") },
        "current_count" => adjustments.count { |row| row["source_kind"] == "current" },
        "carryover_count" => adjustments.count { |row| row["source_kind"] == "carryover" },
        "correction_count" => adjustments.count { |row| row["source_kind"] == "correction" }
      }
    }
    payload["export"] = {
      "id" => batch_id,
      "batch_id" => batch_id,
      "readiness_status" => "finalized",
      "cutoff_at" => payload["cutoff_at"],
      "finalized_at" => "2026-08-31T01:00:01Z",
      "checksum_algorithm" => "SHA-256",
      "checksum_scope" => "payload_without_export",
      "checksum" => TimeTracking::CanonicalPayload.checksum(payload)
    }
    payload
  end

  def setup_records
    company = create(:company)
    workweek = CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: create(:user, company: company),
      confirmed_at: Time.current,
      notes: "Confirmed for batch import tests",
      effective_on: Date.new(2020, 1, 1)
    )
    pay_period = create(
      :pay_period,
      company: company,
      company_workweek: workweek,
      start_date: Date.new(2026, 8, 16),
      end_date: Date.new(2026, 8, 31),
      pay_date: Date.new(2026, 9, 4)
    )
    source = TimeTrackingSource.create!(
      company: company,
      name: "AIRE",
      source_type: "aire_services",
      base_url: "https://aire.example.com",
      shared_secret: "secret"
    )
    [ company, workweek, pay_period, source ]
  end

  it "stores verified batch provenance, payable dimensions, and unpaid exclusions" do
    company, _workweek, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com", pay_rate: 25)
    rate = employee.employee_wage_rates.create!(label: "Flight Hours", rate: 25, is_primary: true, active: true)
    exclusion = {
      "source_time_entry_id" => "202",
      "source_user_id" => "aire-user-1",
      "display_name" => "Pilot One",
      "reason" => "pending_approval",
      "original_work_date" => "2026-08-18",
      "held_total_hours" => 4.0,
      "held_regular_hours" => 4.0,
      "held_overtime_hours" => 0.0
    }
    payload = finalized_payload(start_date: pay_period.start_date, end_date: pay_period.end_date, exclusions: [ exclusion ])
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_batches).and_return(
      "payroll_batches" => [
        { "id" => payload["batch_id"], "start_date" => payload["start_date"], "end_date" => payload["end_date"], "cutoff_at" => payload["cutoff_at"], "checksum" => payload.dig("export", "checksum") }
      ]
    )
    allow(client).to receive(:payroll_batch).with(batch_id: payload["batch_id"]).and_return(payload)

    import = described_class.new(pay_period: pay_period, source: source).call
    row = import.processed_payload.fetch("rows").first

    expect(import).to have_attributes(
      external_batch_id: payload["batch_id"],
      external_batch_checksum: payload.dig("export", "checksum"),
      contract_version: "2.0",
      source_payload_hash: payload.dig("export", "checksum")
    )
    expect(row).to include(
      "employee_id" => employee.id,
      "regular_hours" => 8.0,
      "ready" => true
    )
    expect(row.dig("categories", 0)).to include(
      "payroll_rate_cents" => 2500,
      "employee_wage_rate_id" => rate.id,
      "source_kinds" => [ "current" ],
      "original_work_dates" => [ pay_period.start_date.iso8601 ]
    )
    expect(import.processed_payload.fetch("exclusions")).to contain_exactly(include("reason" => "pending_approval"))
  end

  it "accepts a zero-hour adjustment without category or rate dimensions" do
    company, _workweek, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com")
    zero_adjustment = {
      "source_time_entry_id" => "zero-101",
      "line_key" => "zero-net",
      "source_kind" => "correction",
      "original_work_date" => pay_period.start_date.iso8601,
      "original_week_start" => pay_period.start_date.beginning_of_week(:sunday).iso8601,
      "total_hours" => 0.0,
      "regular_hours" => 0.0,
      "overtime_hours" => 0.0
    }
    payload = finalized_payload(
      start_date: pay_period.start_date,
      end_date: pay_period.end_date,
      employees: [
        {
          "source_user_id" => "aire-user-zero",
          "email" => employee.email,
          "display_name" => employee.full_name,
          "adjustments" => [ zero_adjustment ],
          "total_hours" => 0.0,
          "regular_hours" => 0.0,
          "overtime_hours" => 0.0
        }
      ]
    )
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_batches).and_return(
      "payroll_batches" => [
        {
          "id" => payload["batch_id"],
          "start_date" => payload["start_date"],
          "end_date" => payload["end_date"],
          "cutoff_at" => payload["cutoff_at"],
          "checksum" => payload.dig("export", "checksum")
        }
      ]
    )
    allow(client).to receive(:payroll_batch).and_return(payload)

    row = described_class.new(pay_period: pay_period, source: source).call.processed_payload.fetch("rows").first

    expect(row.fetch("estimated_gross_delta")).to eq(0.0)
    categories = row.fetch("categories")
    expect(categories).to contain_exactly(
      include("name" => "Uncategorized", "total_hours" => 0.0)
    )
    expect(categories.first).not_to have_key("effective_rate_cents")
  end

  it "allows legacy uncategorized payable entries when previewing a committed payroll for reconciliation" do
    company, _workweek, pay_period, source = setup_records
    employee = create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com")
    payload = finalized_payload(start_date: pay_period.start_date, end_date: pay_period.end_date)
    payload["employees"][0]["adjustments"][0].merge!("source_category_id" => nil, "category" => nil)
    payload["issues"]["missing_category_count"] = 1
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    pay_period.update!(status: "committed", committed_at: Time.current)
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_batches).and_return(
      "payroll_batches" => [
        { "id" => payload["batch_id"], "start_date" => payload["start_date"], "end_date" => payload["end_date"], "cutoff_at" => payload["cutoff_at"], "checksum" => payload.dig("export", "checksum") }
      ]
    )
    allow(client).to receive(:payroll_batch).and_return(payload)

    row = described_class.new(pay_period: pay_period, source: source).call.processed_payload.fetch("rows").first

    expect(row).to include("employee_id" => employee.id, "regular_hours" => 8.0)
    expect(row.fetch("categories")).to contain_exactly(include("name" => "Uncategorized", "regular_hours" => 8.0))
  end

  it "keeps legacy uncategorized payable entries blocked for an open payroll import" do
    company, _workweek, pay_period, source = setup_records
    create(:employee, company: company, department: create(:department, company: company), email: "pilot@example.com")
    payload = finalized_payload(start_date: pay_period.start_date, end_date: pay_period.end_date)
    payload["employees"][0]["adjustments"][0].merge!("source_category_id" => nil, "category" => nil)
    payload["issues"]["missing_category_count"] = 1
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_batches).and_return(
      "payroll_batches" => [
        { "id" => payload["batch_id"], "start_date" => payload["start_date"], "end_date" => payload["end_date"], "cutoff_at" => payload["cutoff_at"], "checksum" => payload.dig("export", "checksum") }
      ]
    )
    allow(client).to receive(:payroll_batch).and_return(payload)

    expect do
      described_class.new(pay_period: pay_period, source: source).call
    end.to raise_error(TimeTracking::PayrollBatchPayloadValidator::Error, /category must be an object/)
  end

  it "returns the existing import for the same batch ID and checksum" do
    _company, _workweek, pay_period, source = setup_records
    payload = finalized_payload(start_date: pay_period.start_date, end_date: pay_period.end_date, employees: [])
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(client).to receive(:payroll_batches).and_return(
      "payroll_batches" => [ { "id" => payload["batch_id"], "start_date" => payload["start_date"], "end_date" => payload["end_date"], "cutoff_at" => payload["cutoff_at"], "checksum" => payload.dig("export", "checksum") } ]
    )
    allow(client).to receive(:payroll_batch).and_return(payload)

    first = described_class.new(pay_period: pay_period, source: source).call
    second = described_class.new(pay_period: pay_period, source: source).call

    expect(second.id).to eq(first.id)
    expect(TimeTrackingImport.where(external_batch_id: payload["batch_id"]).count).to eq(1)
  end

  it "rejects a reused batch ID with different valid contents" do
    _company, _workweek, pay_period, source = setup_records
    first_payload = finalized_payload(start_date: pay_period.start_date, end_date: pay_period.end_date, employees: [])
    changed_payload = finalized_payload(
      start_date: pay_period.start_date,
      end_date: pay_period.end_date,
      employees: [],
      exclusions: [
        {
          "source_time_entry_id" => "202",
          "source_user_id" => "99",
          "reason" => "pending_approval",
          "original_work_date" => "2026-08-18",
          "held_total_hours" => 1.0,
          "held_regular_hours" => 1.0,
          "held_overtime_hours" => 0.0
        }
      ]
    )
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(client).to receive(:payroll_batches).and_return(
      { "payroll_batches" => [ { "id" => first_payload["batch_id"], "start_date" => first_payload["start_date"], "end_date" => first_payload["end_date"], "cutoff_at" => first_payload["cutoff_at"], "checksum" => first_payload.dig("export", "checksum") } ] },
      { "payroll_batches" => [ { "id" => changed_payload["batch_id"], "start_date" => changed_payload["start_date"], "end_date" => changed_payload["end_date"], "cutoff_at" => changed_payload["cutoff_at"], "checksum" => changed_payload.dig("export", "checksum") } ] }
    )
    allow(client).to receive(:payroll_batch).and_return(first_payload, changed_payload)

    described_class.new(pay_period: pay_period, source: source).call

    expect do
      described_class.new(pay_period: pay_period, source: source).call
    end.to raise_error(ArgumentError, /different checksum/)
  end

  it "blocks source workweeks that conflict with Payroll's legal workweek" do
    _company, _workweek, pay_period, source = setup_records
    payload = finalized_payload(start_date: pay_period.start_date, end_date: pay_period.end_date)
    payload["employees"][0]["adjustments"][0]["original_work_date"] = "2026-08-17"
    payload["employees"][0]["adjustments"][0]["original_week_start"] = "2026-08-17"
    payload["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(client).to receive(:payroll_batches).and_return(
      "payroll_batches" => [ { "id" => payload["batch_id"], "start_date" => payload["start_date"], "end_date" => payload["end_date"], "cutoff_at" => payload["cutoff_at"], "checksum" => payload.dig("export", "checksum") } ]
    )
    allow(client).to receive(:payroll_batch).and_return(payload)

    expect do
      described_class.new(pay_period: pay_period, source: source).call
    end.to raise_error(ArgumentError, /source workweek does not match/)
  end
end
