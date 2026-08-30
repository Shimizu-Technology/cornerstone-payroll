# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ImportPreviewService do
  def confirm_workweek!(company, starts_on_weekday: 1, starts_at_minutes: 0, confirmed: true)
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: starts_on_weekday,
      starts_at_minutes: starts_at_minutes,
      timezone: "Pacific/Guam",
      source: confirmed ? "operator_confirmed" : "legacy_system_default",
      confirmation_status: confirmed ? "confirmed" : "needs_confirmation",
      confirmed_by: confirmed ? create(:user, company: company) : nil,
      confirmed_at: confirmed ? Time.current : nil,
      notes: confirmed ? "Confirmed for import tests" : nil,
      effective_on: Date.new(2020, 1, 1)
    )
  end

  def complete_export_days(days, start_date: Date.new(2026, 5, 18), end_date: Date.new(2026, 5, 31))
    supplied_by_date = days.index_by { |day| day.fetch("work_date") }
    (start_date..end_date).map do |date|
      supplied_by_date.fetch(date.iso8601) do
        { "work_date" => date.iso8601, "hours" => 0, "categories" => [] }
      end
    end
  end

  describe "#call" do
    it "surfaces category buckets and warns when a multi-rate employee needs earning-type mapping" do
      company = create(:company)
      confirm_workweek!(company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department, email: "cfi@example.com")
      employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: true, active: true)
      employee.employee_wage_rates.create!(label: "Ground School", rate: 45.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company, start_date: Date.new(2026, 5, 18), end_date: Date.new(2026, 5, 31), pay_date: Date.new(2026, 6, 5))
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      raw_payload = {
        "source" => "aire_services",
        "employees" => [
          {
            "source_user_id" => "aire-1",
            "email" => "cfi@example.com",
            "display_name" => "CFI One",
            "days" => complete_export_days([
              {
                "work_date" => "2026-05-18",
                "hours" => 5,
                "categories" => [
                  { "source_category_id" => "sim", "key" => "simulator", "name" => "Simulator", "regular_hours" => 5, "overtime_hours" => 0, "effective_rate_cents" => 55_00 }
                ]
              }
            ]),
            "issues" => {}
          }
        ]
      }
      allow_any_instance_of(TimeTracking::Client).to receive(:time_summary).and_return(raw_payload)

      import = described_class.new(pay_period: pay_period, source: source).call
      row = import.processed_payload.fetch("rows").first

      expect(row.fetch("categories")).to contain_exactly(
        include("source_category_id" => "sim", "key" => "simulator", "name" => "Simulator", "regular_hours" => 5.0, "overtime_hours" => 0.0)
      )
      expect(row.fetch("warnings")).to include(
        include("code" => "unmapped_wage_rate", "source_category_key" => "simulator")
      )
      expect(row.fetch("ready")).to eq(false)
    end

    it "labels category matches made by effective wage rate" do
      company = create(:company)
      confirm_workweek!(company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department, email: "cfi@example.com")
      flight_rate = employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: true, active: true)
      employee.employee_wage_rates.create!(label: "Ground School", rate: 45.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company, start_date: Date.new(2026, 5, 18), end_date: Date.new(2026, 5, 31), pay_date: Date.new(2026, 6, 5))
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      raw_payload = {
        "source" => "aire_services",
        "employees" => [
          {
            "source_user_id" => "aire-1",
            "email" => "cfi@example.com",
            "display_name" => "CFI One",
            "days" => complete_export_days([
              {
                "work_date" => "2026-05-18",
                "hours" => 5,
                "categories" => [
                  { "source_category_id" => "premium", "key" => "premium", "name" => "Premium", "regular_hours" => 5, "overtime_hours" => 0, "effective_rate_cents" => 75_00 }
                ]
              }
            ]),
            "issues" => {}
          }
        ]
      }
      allow_any_instance_of(TimeTracking::Client).to receive(:time_summary).and_return(raw_payload)

      import = described_class.new(pay_period: pay_period, source: source).call
      category = import.processed_payload.dig("rows", 0, "categories", 0)

      expect(category).to include(
        "employee_wage_rate_id" => flight_rate.id,
        "wage_rate_label" => "Flight Instruction",
        "wage_rate_match_method" => "effective_rate"
      )
    end

    it "ignores nil wage rates when matching categories by effective rate" do
      company = create(:company)
      confirm_workweek!(company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department, email: "cfi@example.com")
      employee.employee_wage_rates.create!(label: "Unconfigured", rate: nil, is_primary: true, active: true)
      ground_rate = employee.employee_wage_rates.create!(label: "Ground School", rate: 45.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company, start_date: Date.new(2026, 5, 18), end_date: Date.new(2026, 5, 31), pay_date: Date.new(2026, 6, 5))
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      raw_payload = {
        "source" => "aire_services",
        "employees" => [
          {
            "source_user_id" => "aire-1",
            "email" => "cfi@example.com",
            "display_name" => "CFI One",
            "days" => complete_export_days([
              {
                "work_date" => "2026-05-18",
                "hours" => 5,
                "categories" => [
                  { "source_category_id" => "premium", "key" => "premium", "name" => "Premium", "regular_hours" => 5, "overtime_hours" => 0, "effective_rate_cents" => 45_00 }
                ]
              }
            ]),
            "issues" => {}
          }
        ]
      }
      allow_any_instance_of(TimeTracking::Client).to receive(:time_summary).and_return(raw_payload)

      import = described_class.new(pay_period: pay_period, source: source).call
      category = import.processed_payload.dig("rows", 0, "categories", 0)

      expect(category).to include(
        "employee_wage_rate_id" => ground_rate.id,
        "wage_rate_label" => "Ground School",
        "wage_rate_match_method" => "effective_rate"
      )
    end

    it "does not auto-match short payroll labels by substring" do
      company = create(:company)
      confirm_workweek!(company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department, email: "cfi@example.com")
      employee.employee_wage_rates.create!(label: "Ground", rate: 45.0, is_primary: true, active: true)
      employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company, start_date: Date.new(2026, 5, 18), end_date: Date.new(2026, 5, 31), pay_date: Date.new(2026, 6, 5))
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      raw_payload = {
        "source" => "aire_services",
        "employees" => [
          {
            "source_user_id" => "aire-1",
            "email" => "cfi@example.com",
            "display_name" => "CFI One",
            "days" => complete_export_days([
              {
                "work_date" => "2026-05-18",
                "hours" => 5,
                "categories" => [
                  { "source_category_id" => "ground-school", "key" => "ground_school", "name" => "Ground School", "regular_hours" => 5, "overtime_hours" => 0 }
                ]
              }
            ]),
            "issues" => {}
          }
        ]
      }
      allow_any_instance_of(TimeTracking::Client).to receive(:time_summary).and_return(raw_payload)

      import = described_class.new(pay_period: pay_period, source: source).call
      row = import.processed_payload.fetch("rows").first
      category = row.fetch("categories").first

      expect(category["employee_wage_rate_id"]).to be_nil
      expect(row.fetch("warnings")).to include(
        include("code" => "unmapped_wage_rate", "source_category_name" => "Ground School")
      )
    end

    it "recovers when a concurrent identical preview creates the import first" do
      company = create(:company)
      workweek = confirm_workweek!(company)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      raw_payload = { "source" => "aire_services", "employees" => [] }

      allow_any_instance_of(TimeTracking::Client).to receive(:time_summary).and_return(raw_payload)
      allow(TimeTrackingImport).to receive(:find_or_initialize_by).and_wrap_original do |original, attrs|
        TimeTrackingImport.create!(
          attrs.merge(
            fetch_start_date: TimeTracking::OvertimeCalculator.fetch_start_for(
              pay_period.start_date,
              workweek_start_weekday: workweek.starts_on_weekday
            ),
            fetch_end_date: TimeTracking::OvertimeCalculator.fetch_end_for(
              pay_period.end_date,
              workweek_start_weekday: workweek.starts_on_weekday
            ),
            raw_payload: raw_payload,
            processed_payload: { rows: [] },
            warnings: []
          )
        )
        raise ActiveRecord::RecordNotUnique, "duplicate key value"
      end

      import = described_class.new(pay_period: pay_period, source: source).call

      expect(import).to be_persisted
      expect(import.status).to eq("previewed")
    end

    it "blocks imports until the legal workweek is confirmed without calling the source" do
      company = create(:company)
      confirm_workweek!(company, confirmed: false)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      allow(TimeTracking::Client).to receive(:new)

      expect do
        described_class.new(pay_period: pay_period, source: source).call
      end.to raise_error(ArgumentError, /Confirm the legal overtime workweek/)
      expect(TimeTracking::Client).not_to have_received(:new)
    end

    it "blocks legacy non-midnight workweeks before calling the source" do
      company = create(:company)
      workweek = confirm_workweek!(company)
      workweek.update_column(:starts_at_minutes, 480)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      allow(TimeTracking::Client).to receive(:new)

      expect do
        described_class.new(pay_period: pay_period, source: source).call
      end.to raise_error(ArgumentError, /starts at midnight/)
      expect(TimeTracking::Client).not_to have_received(:new)
    end

    it "blocks dates outside the selected pay period before calling the source" do
      company = create(:company)
      confirm_workweek!(company)
      pay_period = create(
        :pay_period,
        company: company,
        start_date: Date.new(2026, 5, 18),
        end_date: Date.new(2026, 5, 31),
        pay_date: Date.new(2026, 6, 5)
      )
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      allow(TimeTracking::Client).to receive(:new)

      expect do
        described_class.new(
          pay_period: pay_period,
          source: source,
          start_date: pay_period.start_date - 1.day,
          end_date: pay_period.end_date
        ).call
      end.to raise_error(ArgumentError, /must be within the selected pay period/)
      expect(TimeTracking::Client).not_to have_received(:new)
    end

    it "fetches and calculates against the confirmed non-Sunday workweek" do
      company = create(:company)
      workweek = confirm_workweek!(company, starts_on_weekday: 1)
      employee = create(:employee, company: company, department: create(:department, company: company), email: "worker@example.com")
      pay_period = create(
        :pay_period,
        company: company,
        company_workweek: workweek,
        start_date: Date.new(2026, 5, 23),
        end_date: Date.new(2026, 5, 24),
        pay_date: Date.new(2026, 5, 29)
      )
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "custom",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      days = (Date.new(2026, 5, 18)..Date.new(2026, 5, 22)).map do |date|
        { "work_date" => date.iso8601, "hours" => 8 }
      end
      days << { "work_date" => "2026-05-24", "hours" => 8 }
      days = complete_export_days(days, end_date: Date.new(2026, 5, 24))
      raw_payload = {
        "source" => "aire_services",
        "start_date" => "2026-05-18",
        "end_date" => "2026-05-24",
        "employees" => [
          {
            "source_user_id" => "worker-1",
            "email" => employee.email,
            "display_name" => employee.full_name,
            "days" => days,
            "total_hours" => 48,
            "issues" => {}
          }
        ],
        "summary" => { "countable_hours" => 48 }
      }
      expect_any_instance_of(TimeTracking::Client).to receive(:time_summary)
        .with(start_date: "2026-05-18", end_date: "2026-05-24")
        .and_return(raw_payload)

      import = described_class.new(pay_period: pay_period, source: source).call

      row = import.processed_payload.fetch("rows").first
      expect(row).to include("regular_hours" => 0.0, "overtime_hours" => 8.0, "total_hours" => 8.0)
      expect(import.processed_payload.fetch("legal_workweek")).to include(
        "company_workweek_id" => workweek.id,
        "starts_on_weekday" => 1,
        "starts_at_minutes" => 0
      )
      expect(import.processed_payload).to include(
        "schema_version" => "1.0",
        "validation_version" => "time_summary_v1"
      )
    end
  end
end
