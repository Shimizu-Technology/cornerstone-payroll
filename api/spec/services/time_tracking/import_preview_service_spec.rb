# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ImportPreviewService do
  describe "#call" do
    it "surfaces category buckets and warns when a multi-rate employee needs earning-type mapping" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department, email: "cfi@example.com")
      employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: true, active: true)
      employee.employee_wage_rates.create!(label: "Ground School", rate: 45.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company, start_date: Date.new(2026, 5, 18), end_date: Date.new(2026, 5, 31), pay_date: Date.new(2026, 6, 5))
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
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
            "days" => [
              {
                "work_date" => "2026-05-18",
                "hours" => 5,
                "categories" => [
                  { "source_category_id" => "sim", "key" => "simulator", "name" => "Simulator", "regular_hours" => 5, "overtime_hours" => 0, "effective_rate_cents" => 55_00 }
                ]
              }
            ],
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
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department, email: "cfi@example.com")
      flight_rate = employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: true, active: true)
      employee.employee_wage_rates.create!(label: "Ground School", rate: 45.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company, start_date: Date.new(2026, 5, 18), end_date: Date.new(2026, 5, 31), pay_date: Date.new(2026, 6, 5))
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
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
            "days" => [
              {
                "work_date" => "2026-05-18",
                "hours" => 5,
                "categories" => [
                  { "source_category_id" => "premium", "key" => "premium", "name" => "Premium", "regular_hours" => 5, "overtime_hours" => 0, "effective_rate_cents" => 75_00 }
                ]
              }
            ],
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

    it "does not auto-match short payroll labels by substring" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department, email: "cfi@example.com")
      employee.employee_wage_rates.create!(label: "Ground", rate: 45.0, is_primary: true, active: true)
      employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company, start_date: Date.new(2026, 5, 18), end_date: Date.new(2026, 5, 31), pay_date: Date.new(2026, 6, 5))
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
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
            "days" => [
              {
                "work_date" => "2026-05-18",
                "hours" => 5,
                "categories" => [
                  { "source_category_id" => "ground-school", "key" => "ground_school", "name" => "Ground School", "regular_hours" => 5, "overtime_hours" => 0 }
                ]
              }
            ],
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
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      raw_payload = { "source" => "aire_services", "employees" => [] }

      allow_any_instance_of(TimeTracking::Client).to receive(:time_summary).and_return(raw_payload)
      allow(TimeTrackingImport).to receive(:find_or_initialize_by).and_wrap_original do |original, attrs|
        TimeTrackingImport.create!(
          attrs.merge(
            fetch_start_date: TimeTracking::OvertimeCalculator.fetch_start_for(pay_period.start_date),
            fetch_end_date: TimeTracking::OvertimeCalculator.fetch_end_for(pay_period.end_date),
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
  end
end
