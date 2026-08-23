# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"

class E2eReleaseFixture
  SYNTHETIC_ORGANIZATION_SLUG = "gate-0-synthetic-firm"
  SOURCE_SECRET = "gate0-fixture-secret-must-never-leak"

  class << self
    def seed!(output_path:)
      verify_safe_environment!
      verify_empty_application_data!
      verify_tax_configuration!

      fixture = ApplicationRecord.transaction do
        build_fixture
      end

      write_fixture!(output_path, fixture)
      fixture
    end

    private

    def verify_safe_environment!
      return if Rails.env.test? && ENV["E2E_TEST_MODE"] == "true"

      raise "The Gate 0 E2E fixture may run only in Rails test with E2E_TEST_MODE=true"
    end

    def verify_empty_application_data!
      populated = {
        organizations: Organization.count,
        companies: Company.count,
        users: User.count,
        employees: Employee.count,
        pay_periods: PayPeriod.count
      }.reject { |_name, count| count.zero? }
      return if populated.empty?

      raise "Refusing to seed the Gate 0 E2E fixture into a populated database: #{populated.inspect}"
    end

    def verify_tax_configuration!
      return if AnnualTaxConfig.for_year(2026)&.config_for("single")

      raise "Seed the 2026 tax configuration before preparing the Gate 0 E2E fixture"
    end

    def build_fixture
      organization = Organization.create!(
        name: "Gate 0 Synthetic Firm",
        slug: SYNTHETIC_ORGANIZATION_SLUG,
        status: "active"
      )
      company = organization.companies.create!(
        name: "Synthetic Payroll Company",
        address_line1: "100 Test Avenue",
        city: "Hagåtña",
        state: "GU",
        zip: "96910",
        phone: "(671) 555-0100",
        email: "payroll-fixture@example.test",
        pay_frequency: "biweekly",
        ein: "00-0000001"
      )
      other_company = organization.companies.create!(
        name: "Synthetic Boundary Company",
        city: "Tamuning",
        state: "GU",
        zip: "96913",
        pay_frequency: "biweekly",
        ein: "00-0000002"
      )
      organization.update!(primary_company: company)

      admin = User.create!(
        organization: organization,
        company: company,
        email: "gate0-admin@example.test",
        name: "Gate 0 Admin",
        role: "org_admin",
        active: true
      )
      client = User.create!(
        organization: organization,
        company: company,
        email: "gate0-client@example.test",
        name: "Gate 0 Client",
        role: "client",
        active: true
      )
      CompanyAssignment.create!(user: client, company: company)
      inactive_user = User.create!(
        organization: organization,
        company: company,
        email: "gate0-inactive@example.test",
        name: "Gate 0 Inactive User",
        role: "accountant",
        active: false
      )

      workweek = CompanyWorkweek.create!(
        company: company,
        starts_on_weekday: 0,
        starts_at_minutes: 0,
        timezone: "Pacific/Guam",
        source: "operator_confirmed",
        confirmation_status: "confirmed",
        confirmed_by: admin,
        confirmed_at: Time.utc(2026, 1, 1, 0, 0, 0),
        notes: "Synthetic Sunday workweek confirmed for Gate 0",
        effective_on: Date.new(2026, 1, 1)
      )
      pay_schedule = CompanyPaySchedule.create!(
        company: company,
        frequency: "biweekly",
        period_rule: "biweekly",
        pay_date_rule: "days_after_period_end",
        pay_date_offset_days: 6,
        period_start_weekday: 0,
        period_anchor_date: Date.new(2026, 1, 4),
        timezone: "Pacific/Guam",
        source: "operator_confirmed",
        confirmation_status: "confirmed",
        confirmed_by: admin,
        confirmed_at: Time.utc(2026, 1, 1, 0, 0, 0),
        notes: "Synthetic biweekly schedule confirmed for Gate 0",
        effective_on: Date.new(2026, 1, 1)
      )

      department = Department.create!(company: company, name: "Synthetic Operations")
      other_department = Department.create!(company: other_company, name: "Boundary Operations")
      employee = create_employee!(
        company: company,
        department: department,
        first_name: "Avery",
        last_name: "Example",
        email: "avery@example.test",
        ssn: "900-00-0001",
        pay_rate: 22.50,
        hire_date: Date.new(2026, 1, 1)
      )
      client_employee = create_employee!(
        company: company,
        department: department,
        first_name: "Casey",
        last_name: "Fixture",
        email: "casey@example.test",
        ssn: "900-00-0002",
        pay_rate: 18.75,
        hire_date: Date.new(2027, 1, 1)
      )
      other_employee = create_employee!(
        company: other_company,
        department: other_department,
        first_name: "Jordan",
        last_name: "Boundary",
        email: "jordan@example.test",
        ssn: "900-00-0003",
        pay_rate: 19.25,
        hire_date: Date.new(2026, 1, 1)
      )

      workflow_period = create_pay_period!(
        company: company,
        pay_schedule: pay_schedule,
        workweek: workweek,
        start_date: Date.new(2026, 8, 2),
        end_date: Date.new(2026, 8, 15),
        pay_date: Date.new(2026, 8, 21),
        notes: "Gate 0 lifecycle scenario"
      )
      PayrollItem.create!(
        company: company,
        pay_period: workflow_period,
        employee: employee,
        employment_type: employee.employment_type,
        pay_rate: employee.pay_rate,
        hours_worked: 40,
        overtime_hours: 0,
        timekeeping_source: "manual"
      )

      time_import_period = create_pay_period!(
        company: company,
        pay_schedule: pay_schedule,
        workweek: workweek,
        start_date: Date.new(2026, 8, 16),
        end_date: Date.new(2026, 8, 29),
        pay_date: Date.new(2026, 9, 4),
        notes: "Gate 0 time-import scenario"
      )
      source = TimeTrackingSource.create!(
        company: company,
        name: "Unavailable Synthetic Source",
        source_type: "custom",
        base_url: "http://127.0.0.1:59999",
        shared_secret: SOURCE_SECRET,
        active: true
      )
      first_import = create_time_import!(
        pay_period: time_import_period,
        source: source,
        employee: employee,
        workweek: workweek,
        payload_key: "first"
      )
      retry_import = create_time_import!(
        pay_period: time_import_period,
        source: source,
        employee: employee,
        workweek: workweek,
        payload_key: "retry"
      )

      {
        schema_version: 1,
        organization_id: organization.id,
        company_id: company.id,
        other_company_id: other_company.id,
        admin_email: admin.email,
        client_email: client.email,
        inactive_user_email: inactive_user.email,
        employee_id: employee.id,
        client_employee_id: client_employee.id,
        other_employee_id: other_employee.id,
        workflow_pay_period_id: workflow_period.id,
        workflow_payroll_item_id: workflow_period.payroll_items.find_by!(employee: employee).id,
        time_import_pay_period_id: time_import_period.id,
        time_tracking_source_id: source.id,
        first_time_import_id: first_import.id,
        retry_time_import_id: retry_import.id,
        original_client_pay_rate: client_employee.pay_rate.to_f,
        original_client_ssn_last_four: client_employee.ssn_last_four
      }
    end

    def create_employee!(company:, department:, first_name:, last_name:, email:, ssn:, pay_rate:, hire_date:)
      Employee.create!(
        company: company,
        department: department,
        first_name: first_name,
        last_name: last_name,
        email: email,
        ssn_encrypted: ssn,
        employment_type: "hourly",
        pay_rate: pay_rate,
        pay_frequency: "biweekly",
        status: "active",
        filing_status: "single",
        allowances: 0,
        hire_date: hire_date,
        address_line1: "100 Test Avenue",
        city: "Hagåtña",
        state: "GU",
        zip: "96910"
      )
    end

    def create_pay_period!(company:, pay_schedule:, workweek:, start_date:, end_date:, pay_date:, notes:)
      PayPeriod.create!(
        company: company,
        company_pay_schedule: pay_schedule,
        company_workweek: workweek,
        start_date: start_date,
        end_date: end_date,
        pay_date: pay_date,
        status: "draft",
        notes: notes,
        run_purpose: "regular",
        run_purpose_source: "operator_selected",
        includes_base_salary: true
      )
    end

    def create_time_import!(pay_period:, source:, employee:, workweek:, payload_key:)
      TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("gate-0-#{payload_key}"),
        raw_payload: { "fixture" => payload_key },
        processed_payload: {
          "schema_version" => "1.0",
          "validation_version" => "time_summary_v1",
          "start_date" => pay_period.start_date.iso8601,
          "end_date" => pay_period.end_date.iso8601,
          "legal_workweek" => {
            "company_workweek_id" => workweek.id,
            "starts_on_weekday" => workweek.starts_on_weekday,
            "starts_at_minutes" => workweek.starts_at_minutes,
            "timezone" => workweek.timezone
          },
          "rows" => [
            {
              "source_user_id" => "synthetic-worker-1",
              "source_email" => "avery@example.test",
              "source_display_name" => "Avery Example",
              "employee_id" => employee.id,
              "regular_hours" => 76.0,
              "overtime_hours" => 4.0,
              "warnings" => []
            }
          ]
        }
      )
    end

    def write_fixture!(output_path, fixture)
      path = Pathname(output_path)
      FileUtils.mkdir_p(path.dirname)
      path.write(JSON.pretty_generate(fixture))
    end
  end
end
