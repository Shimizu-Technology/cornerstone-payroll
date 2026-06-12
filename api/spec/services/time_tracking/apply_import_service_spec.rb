# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ApplyImportService do
  describe "#call" do
    it "preserves existing holiday and PTO hours when applying imported regular and overtime hours" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      pay_period = create(:pay_period, company: company)
      user = create(:user, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 72.0,
              "overtime_hours" => 4.0,
              "warnings" => []
            }
          ]
        }
      )
      item = create(
        :payroll_item,
        company: company,
        pay_period: pay_period,
        employee: employee,
        holiday_hours: 8.0,
        pto_hours: 4.0,
        hours_worked: 0,
        overtime_hours: 0
      )

      described_class.new(import: import, mappings: [], applied_by: user).call

      item.reload
      expect(item.hours_worked).to eq(72.0)
      expect(item.overtime_hours).to eq(4.0)
      expect(item.holiday_hours).to eq(8.0)
      expect(item.pto_hours).to eq(4.0)
    end

    it "applies source category buckets to payroll wage rate hours for multi-rate employees" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      flight_rate = employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: true, active: true)
      ground_rate = employee.employee_wage_rates.create!(label: "Ground School", rate: 45.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("multi-rate-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "cfi@example.com",
              "source_display_name" => "CFI One",
              "employee_id" => employee.id,
              "regular_hours" => 22.0,
              "overtime_hours" => 3.0,
              "categories" => [
                { "source_category_id" => "flight", "key" => "flight_instruction", "name" => "Flight Instruction", "regular_hours" => 10.0, "overtime_hours" => 3.0, "total_hours" => 13.0, "employee_wage_rate_id" => flight_rate.id },
                { "source_category_id" => "ground", "key" => "ground_school", "name" => "Ground School", "regular_hours" => 12.0, "overtime_hours" => 0.0, "total_hours" => 12.0, "employee_wage_rate_id" => ground_rate.id }
              ],
              "warnings" => []
            }
          ]
        }
      )

      results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(results[:errors]).to be_empty
      item = pay_period.payroll_items.find_by!(employee: employee)
      expect(item.hours_worked).to eq(22.0)
      expect(item.overtime_hours).to eq(3.0)
      expect(item.wage_rate_hours).to contain_exactly(
        include("employee_wage_rate_id" => flight_rate.id, "label" => "Flight Instruction", "rate" => 75.0, "regular_hours" => 10.0, "overtime_hours" => 3.0),
        include("employee_wage_rate_id" => ground_rate.id, "label" => "Ground School", "rate" => 45.0, "regular_hours" => 12.0, "overtime_hours" => 0.0)
      )
    end

    it "applies user-supplied wage-rate mappings when the stored preview has unmapped wage-rate warnings" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department, email: "cfi@example.com")
      flight_rate = employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: true, active: true)
      employee.employee_wage_rates.create!(label: "Ground School", rate: 45.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company)
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
            "source_user_id" => "source-1",
            "email" => "cfi@example.com",
            "display_name" => "CFI One",
            "days" => [
              {
                "work_date" => pay_period.start_date.iso8601,
                "hours" => 8.0,
                "categories" => [
                  { "source_category_id" => "sim", "key" => "simulator", "name" => "Simulator", "total_hours" => 8.0, "regular_hours" => 8.0, "overtime_hours" => 0.0 }
                ]
              }
            ],
            "issues" => {}
          }
        ]
      }
      allow_any_instance_of(TimeTracking::Client).to receive(:time_summary).and_return(raw_payload)
      import = TimeTracking::ImportPreviewService.new(pay_period: pay_period, source: source).call

      expect(import.processed_payload.dig("rows", 0, "warnings")).to include(
        include("code" => "unmapped_wage_rate", "source_category_key" => "simulator")
      )

      results = described_class.new(
        import: import,
        mappings: [
          {
            source_user_id: "source-1",
            employee_id: employee.id,
            include: true,
            wage_rate_mappings: [
              { source_category_id: "sim", source_category_key: "simulator", source_category_name: "Simulator", employee_wage_rate_id: flight_rate.id }
            ]
          }
        ],
        applied_by: create(:user, company: company)
      ).call

      expect(results[:errors]).to be_empty
      item = pay_period.payroll_items.find_by!(employee: employee)
      expect(item.wage_rate_hours).to include(
        include("employee_wage_rate_id" => flight_rate.id, "regular_hours" => 8.0, "overtime_hours" => 0.0)
      )
    end

    it "requires source categories to be mapped for multi-rate employees" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      employee.employee_wage_rates.create!(label: "Flight Instruction", rate: 75.0, is_primary: true, active: true)
      employee.employee_wage_rates.create!(label: "Ground School", rate: 45.0, is_primary: false, active: true)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("unmapped-multi-rate-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "cfi@example.com",
              "source_display_name" => "CFI One",
              "employee_id" => employee.id,
              "regular_hours" => 10.0,
              "overtime_hours" => 0.0,
              "categories" => [
                { "source_category_id" => "sim", "key" => "simulator", "name" => "Simulator", "regular_hours" => 10.0, "overtime_hours" => 0.0, "total_hours" => 10.0 }
              ],
              "warnings" => []
            }
          ]
        }
      )

      results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(results[:errors]).to contain_exactly(
        hash_including(source_user_id: "source-1", employee_id: employee.id, error: "Map Simulator to one of this employee's payroll earning types before importing.")
      )
      expect(pay_period.payroll_items.find_by(employee: employee)).to be_nil
    end

    it "treats an unmatched-employee warning as resolved when an employee mapping is supplied" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("mapped-warning-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => nil,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => [ { "code" => "unmatched_employee", "message" => "Map this source user" } ]
            }
          ]
        }
      )

      results = described_class.new(
        import: import,
        mappings: [ { source_user_id: "source-1", employee_id: employee.id, include: true } ],
        applied_by: create(:user, company: company)
      ).call

      expect(results[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee).hours_worked).to eq(40.0)
    end

    it "recovers when a concurrent apply creates the employee mapping first" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("concurrent-mapping-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => []
            }
          ]
        }
      )
      lookup_attrs = {
        company: company,
        time_tracking_source: source,
        source_user_id: "source-1"
      }

      mapping = TimeTrackingEmployeeMapping.create!(lookup_attrs.merge(employee: employee))
      allow(TimeTrackingEmployeeMapping).to receive(:find_by).and_call_original
      allow(TimeTrackingEmployeeMapping).to receive(:find_by).with(lookup_attrs).and_return(nil, mapping)
      allow_any_instance_of(described_class).to receive(:create_mapping!).with(lookup_attrs, employee)
        .and_raise(ActiveRecord::RecordNotUnique, "duplicate key value")

      results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(results[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee).hours_worked).to eq(40.0)
    end

    it "rejects duplicate source rows mapped to the same payroll employee" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("duplicate-employee-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => []
            },
            {
              "source_user_id" => "source-2",
              "source_email" => "worker-alias@example.com",
              "source_display_name" => "Worker Alias",
              "employee_id" => employee.id,
              "regular_hours" => 8.0,
              "overtime_hours" => 2.0,
              "warnings" => []
            }
          ]
        }
      )

      results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(results[:errors]).to contain_exactly(
        hash_including(source_user_id: "source-2", employee_id: employee.id, error: "Duplicate payroll employee mapping")
      )
      expect(import.reload.status).to eq("previewed")
      expect(pay_period.payroll_items.find_by(employee: employee)).to be_nil
    end

    it "does not overwrite payroll items imported from another time tracking import" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("cross-import-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => []
            }
          ]
        }
      )
      item = create(
        :payroll_item,
        company: company,
        pay_period: pay_period,
        employee: employee,
        hours_worked: 32.0,
        overtime_hours: 2.0,
        import_source: "time_tracking:cornerstone_tax:999"
      )

      results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(results[:errors]).to contain_exactly(
        hash_including(source_user_id: "source-1", employee_id: employee.id, error: "Employee already has imported time tracking hours in this pay period")
      )
      expect(import.reload.status).to eq("previewed")
      expect(item.reload.hours_worked).to eq(32.0)
      expect(item.overtime_hours).to eq(2.0)
    end

    it "rejects variable salary employees without period pay before applying time tracking hours" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(
        :employee,
        company: company,
        department: department,
        employment_type: "salary",
        salary_type: "variable",
        pay_rate: 100_000
      )
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("variable-salary-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => []
            }
          ]
        }
      )

      results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(results[:errors]).to contain_exactly(
        hash_including(
          source_user_id: "source-1",
          employee_id: employee.id,
          error: "Enter this employee's variable salary amount for the pay period before applying time tracking hours."
        )
      )
      expect(import.reload.status).to eq("previewed")
      expect(pay_period.payroll_items.find_by(employee: employee)).to be_nil
      expect(TimeTrackingEmployeeMapping.find_by(source_user_id: "source-1")).to be_nil
    end

    it "allows variable salary employees with period pay already entered when applying time tracking hours" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(
        :employee,
        company: company,
        department: department,
        employment_type: "salary",
        salary_type: "variable",
        pay_rate: 100_000
      )
      pay_period = create(:pay_period, company: company)
      item = create(:payroll_item, company: company, pay_period: pay_period, employee: employee, employment_type: "salary", salary_override: 1_000.0)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("variable-salary-with-pay-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => []
            }
          ]
        }
      )

      results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(results[:errors]).to be_empty
      expect(item.reload.salary_override).to eq(1_000.0)
      expect(item.hours_worked).to eq(40.0)
    end

    it "copies recurring payroll adjustments to new payroll items from time tracking imports" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(
        :employee,
        company: company,
        department: department,
        default_payroll_adjustments: [
          { "label" => "Recurring reimbursement", "amount" => 25.0, "treatment" => "non_taxable_addition", "active" => true }
        ]
      )
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("adjustment-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => []
            }
          ]
        }
      )

      described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(pay_period.payroll_items.find_by!(employee: employee).payroll_adjustments).to contain_exactly(
        include("label" => "Recurring reimbursement", "amount" => 25.0, "treatment" => "non_taxable_addition")
      )
    end

    it "does not overwrite manually overridden payroll adjustments on existing payroll items" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(
        :employee,
        company: company,
        department: department,
        default_payroll_adjustments: [
          { "label" => "Default reimbursement", "amount" => 25.0, "treatment" => "non_taxable_addition", "active" => true }
        ]
      )
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("preserve-manual-adjustment-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => []
            }
          ]
        }
      )
      item = create(
        :payroll_item,
        company: company,
        pay_period: pay_period,
        employee: employee,
        payroll_adjustments: [
          { "label" => "Manual pre-tax deduction", "amount" => 10.0, "treatment" => "pre_tax_deduction", "active" => true }
        ]
      )
      item.mark_payroll_adjustments_overridden!
      item.save!

      described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(item.reload.payroll_adjustments).to contain_exactly(
        include("label" => "Manual pre-tax deduction", "amount" => 10.0, "treatment" => "pre_tax_deduction")
      )
    end

    it "does not apply an import that is already applied" do
      company = create(:company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: create(:pay_period, company: company),
        time_tracking_source: source,
        start_date: Date.new(2024, 1, 1),
        end_date: Date.new(2024, 1, 14),
        fetch_start_date: Date.new(2024, 1, 1),
        fetch_end_date: Date.new(2024, 1, 14),
        source_payload_hash: Digest::SHA256.hexdigest("payload"),
        processed_payload: { "rows" => [] },
        status: "applied"
      )

      expect do
        described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call
      end.to raise_error(ArgumentError, "Only previewed time tracking imports can be applied")
    end
  end
end
