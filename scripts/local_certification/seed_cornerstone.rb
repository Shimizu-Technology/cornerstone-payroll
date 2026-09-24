# frozen_string_literal: true

require "json"

database_name = ActiveRecord::Base.connection_db_config.database.to_s
unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" && database_name.start_with?("cornerstone_aire_certification_")
  abort "Refusing to seed outside an isolated Cornerstone certification test database"
end

input_path = ENV.fetch("AIRE_CERTIFICATION_FIXTURE_PATH")
output_path = ENV.fetch("CERTIFICATION_FIXTURE_PATH")
aire_base_url = ENV.fetch("AIRE_BASE_URL")
aire = JSON.parse(File.read(input_path))
abort "Unsupported AIRE certification fixture" unless aire.fetch("schema_version") == 1

populated = {
  organizations: Organization.count,
  companies: Company.count,
  users: User.count,
  employees: Employee.count,
  pay_periods: PayPeriod.count
}.reject { |_name, count| count.zero? }
abort "Refusing to seed a populated Cornerstone certification database: #{populated.inspect}" if populated.any?

start_date = Date.iso8601(aire.fetch("start_date"))
end_date = Date.iso8601(aire.fetch("end_date"))
pay_date = Date.iso8601(aire.fetch("pay_date"))
cutoff_at = Time.iso8601(aire.fetch("cutoff_at"))
cutoff_minutes = cutoff_at.in_time_zone("Pacific/Guam").then { |time| (time.hour * 60) + time.min }
next_start_date = end_date + 1.day
next_end_date = next_start_date.day == 16 ? next_start_date.end_of_month : next_start_date.change(day: 15)
next_pay_date = next_end_date + 1.day

fixture = ApplicationRecord.transaction do
  organization = Organization.create!(
    name: "Local AIRE Certification Firm",
    slug: "local-aire-certification-firm",
    status: "active"
  )
  company = organization.companies.create!(
    name: "Local AIRE Certification Company",
    address_line1: "100 Local Test Lane",
    city: "Hagåtña",
    state: "GU",
    zip: "96910",
    phone: "(671) 555-0199",
    email: "payroll-certification@example.test",
    pay_frequency: "semimonthly",
    ein: "00-0000099"
  )
  organization.update!(primary_company: company)
  admin = User.create!(
    organization: organization,
    company: company,
    email: "cornerstone-certification-admin@example.test",
    name: "Chels Certification",
    role: "org_admin",
    active: true
  )
  workweek = CompanyWorkweek.create!(
    company: company,
    starts_on_weekday: 0,
    starts_at_minutes: 0,
    timezone: "Pacific/Guam",
    source: "operator_confirmed",
    confirmation_status: "confirmed",
    confirmed_by: admin,
    confirmed_at: Time.current,
    notes: "Confirmed for the isolated AIRE certification",
    effective_on: start_date.beginning_of_year
  )
  schedule = CompanyPaySchedule.create!(
    company: company,
    frequency: "semimonthly",
    period_rule: "semimonthly",
    pay_date_rule: "manual",
    timezone: "Pacific/Guam",
    source: "operator_confirmed",
    confirmation_status: "confirmed",
    confirmed_by: admin,
    confirmed_at: Time.current,
    notes: "Confirmed for the isolated AIRE certification",
    effective_on: start_date.beginning_of_year,
    payroll_cutoff_days_before: 7,
    payroll_cutoff_at_minutes: cutoff_minutes
  )
  department = Department.create!(company: company, name: "Certification Operations")
  employee = Employee.create!(
    company: company,
    department: department,
    first_name: "Ari",
    last_name: "Worker",
    email: aire.fetch("employee_email"),
    ssn_encrypted: "900-00-0099",
    employment_type: "hourly",
    pay_rate: 25,
    pay_frequency: "semimonthly",
    status: "active",
    filing_status: "single",
    allowances: 0,
    additional_withholding: 0,
    retirement_rate: 0,
    roth_retirement_rate: 0,
    hire_date: start_date - 1.year,
    address_line1: "101 Local Test Lane",
    city: "Hagåtña",
    state: "GU",
    zip: "96910"
  )
  wage_rate = EmployeeWageRate.create!(
    employee: employee,
    label: aire.fetch("category_name"),
    rate: 25,
    is_primary: true,
    active: true
  )
  EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: admin)
  employee.employee_document_requirements.find_each do |requirement|
    EmployeeDocumentRequirementReviewService.new(
      requirement: requirement,
      actor: admin,
      attributes: {
        status: "waived",
        review_note: "Synthetic certification employee; no real payroll or filing",
        lock_version: requirement.lock_version
      }
    ).call!
  end

  source = TimeTrackingSource.create!(
    company: company,
    name: "Local AIRE Services",
    source_type: "aire_services",
    base_url: aire_base_url,
    shared_secret: aire.fetch("shared_secret"),
    active: true
  )
  TimeTrackingDelegation.create!(
    company: company,
    time_tracking_source: source,
    user: admin,
    token: aire.fetch("delegation_token")
  )
  TimeTrackingEmployeeMapping.create!(
    company: company,
    time_tracking_source: source,
    employee: employee,
    source_user_id: aire.fetch("employee_id").to_s,
    source_user_uuid: aire.fetch("employee_uuid")
  )
  pay_period = PayPeriod.create!(
    company: company,
    company_pay_schedule: schedule,
    company_workweek: workweek,
    start_date: start_date,
    end_date: end_date,
    pay_date: pay_date,
    status: "draft",
    notes: "Synthetic local AIRE integration certification; never production"
  )
  next_pay_period = PayPeriod.create!(
    company: company,
    company_pay_schedule: schedule,
    company_workweek: workweek,
    start_date: next_start_date,
    end_date: next_end_date,
    pay_date: next_pay_date,
    status: "draft",
    notes: "Synthetic next AIRE period for held-time certification; never production"
  )

  {
    schema_version: 1,
    company_id: company.id,
    admin_email: admin.email,
    employee_id: employee.id,
    employee_wage_rate_id: wage_rate.id,
    source_id: source.id,
    pay_period_id: pay_period.id,
    next_pay_period_id: next_pay_period.id,
    start_date: start_date.iso8601,
    end_date: end_date.iso8601,
    pay_date: pay_date.iso8601,
    next_start_date: next_start_date.iso8601,
    next_end_date: next_end_date.iso8601,
    next_pay_date: next_pay_date.iso8601,
    cutoff_at: cutoff_at.iso8601
  }
end

File.write(output_path, JSON.pretty_generate(fixture))
puts "Seeded isolated Cornerstone certification fixture (secrets withheld)"
