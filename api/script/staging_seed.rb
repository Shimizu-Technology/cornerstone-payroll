# frozen_string_literal: true

unless Rails.env.production? && ENV["DEPLOYMENT_ENV"] == "staging" && ENV["STAGING_SEED_ALLOWED"] == "true"
  abort "Refusing to seed outside the explicit Cornerstone staging deployment"
end

database_name = ActiveRecord::Base.connection_db_config.database.to_s
abort "Refusing to seed an unexpected database" unless database_name == "cornerstone_payroll_staging"

slug = "aire-payroll-staging"
if Organization.exists?(slug: slug)
  puts "Cornerstone staging fixture already exists"
  exit
end

guam = ActiveSupport::TimeZone["Pacific/Guam"]
now = guam.now

period_for = lambda do |date|
  if date.day <= 15
    [ date.beginning_of_month, date.change(day: 15) ]
  else
    [ date.change(day: 16), date.end_of_month ]
  end
end

periods = (-4..1).map do |offset|
  reference = now.to_date.advance(months: offset)
  [ period_for.call(reference.change(day: 1)), period_for.call(reference.change(day: 16)) ]
end.flatten(1).uniq.sort_by(&:first)

manual_dates = periods.select do |(_start_date, end_date)|
  pay_date = end_date + 1.day
  cutoff_date = pay_date + 7.days
  guam.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 17, 0) < now
end.last or abort "No completed semimonthly staging period is available"

manual_index = periods.index(manual_dates)
connected_dates = periods.fetch(manual_index + 1)

admin_clerk_id = ENV.fetch("PAYROLL_STAGING_ADMIN_CLERK_ID")
admin_email = ENV.fetch("STAGING_ADMIN_EMAIL")
integration_secret = ENV.fetch("PAYROLL_SHARED_SECRET")

ActiveRecord::Base.transaction do
  organization = Organization.create!(
    id: 900_001,
    name: "AIRE + Cornerstone Staging",
    slug: slug,
    status: "active"
  )
  company = organization.companies.create!(
    id: 900_001,
    name: "Staging Flight Operations",
    address_line1: "100 Test Flight Lane",
    city: "Hagåtña",
    state: "GU",
    zip: "96910",
    phone: "(671) 555-0199",
    email: "payroll-staging@example.test",
    pay_frequency: "semimonthly",
    ein: "00-0000098"
  )
  organization.update!(primary_company: company)
  admin = User.create!(
    id: 900_001,
    organization: organization,
    company: company,
    clerk_id: admin_clerk_id,
    email: admin_email,
    name: "Chels Staging",
    role: "org_admin",
    invitation_status: "accepted",
    active: true
  )

  manual_start, manual_end = manual_dates
  connected_start, connected_end = connected_dates
  foundation_date = manual_start.beginning_of_year
  workweek = CompanyWorkweek.create!(
    company: company,
    starts_on_weekday: 0,
    starts_at_minutes: 0,
    timezone: "Pacific/Guam",
    source: "operator_confirmed",
    confirmation_status: "confirmed",
    confirmed_by: admin,
    confirmed_at: now,
    notes: "Confirmed for the isolated staging workflow",
    effective_on: foundation_date
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
    confirmed_at: now,
    notes: "Confirmed for the isolated staging workflow",
    effective_on: foundation_date,
    payroll_cutoff_days_before: 7,
    payroll_cutoff_at_minutes: 1_020
  )
  department = Department.create!(company: company, name: "Staging Operations")

  create_employee = lambda do |id:, first_name:, last_name:, email:, rate:, label:, ssn:|
    employee = Employee.create!(
      id: id,
      company: company,
      department: department,
      first_name: first_name,
      last_name: last_name,
      email: email,
      ssn_encrypted: ssn,
      employment_type: "hourly",
      pay_rate: rate,
      pay_frequency: "semimonthly",
      status: "active",
      filing_status: "single",
      allowances: 0,
      additional_withholding: 0,
      retirement_rate: 0,
      roth_retirement_rate: 0,
      hire_date: manual_start - 1.year,
      address_line1: "#{id - 900_000} Test Employee Lane",
      city: "Hagåtña",
      state: "GU",
      zip: "96910",
      payment_delivery_method: "paper_check"
    )
    wage_rate = EmployeeWageRate.create!(
      employee: employee,
      label: label,
      rate: rate,
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
          review_note: "Synthetic staging employee; no real payroll or filing",
          lock_version: requirement.lock_version
        }
      ).call!
    end
    [ employee, wage_rate ]
  end

  ari, = create_employee.call(
    id: 900_101,
    first_name: "Ari",
    last_name: "Manual",
    email: "ari.manual@example.test",
    rate: 25,
    label: "Staging Manual Operations",
    ssn: "900-00-0101"
  )
  casey, = create_employee.call(
    id: 900_102,
    first_name: "Casey",
    last_name: "Connected",
    email: "casey.connected@example.test",
    rate: 20,
    label: "Staging Connected Operations",
    ssn: "900-00-0102"
  )

  source = TimeTrackingSource.create!(
    id: 900_001,
    company: company,
    name: "AIRE Staging",
    source_type: "aire_services",
    base_url: "http://aire-api:3000",
    shared_secret: integration_secret,
    active: true
  )
  [
    [ ari, 900_101, "00000000-0000-4000-8000-000000000101" ],
    [ casey, 900_102, "00000000-0000-4000-8000-000000000102" ]
  ].each do |employee, source_user_id, source_user_uuid|
    TimeTrackingEmployeeMapping.create!(
      company: company,
      time_tracking_source: source,
      employee: employee,
      source_user_id: source_user_id.to_s,
      source_user_uuid: source_user_uuid
    )
  end

  build_period = lambda do |id:, dates:, source_state:|
    start_date, end_date = dates
    pay_period = PayPeriod.create!(
      id: id,
      company: company,
      company_pay_schedule: schedule,
      company_workweek: workweek,
      start_date: start_date,
      end_date: end_date,
      pay_date: end_date + 1.day,
      status: "draft",
      cycle: "regular",
      run_purpose: "regular",
      run_purpose_source: "operator_selected",
      notes: "Synthetic staging payroll; never production"
    )
    external_id = format("00000000-0000-4000-8000-%012d", id)
    publication_id = format("00000000-0000-4000-9000-%012d", id)
    calendar = AirePayrollCalendarPeriod.create!(
      company: company,
      time_tracking_source: source,
      pay_period: pay_period,
      external_pay_period_id: external_id
    )
    payload = AirePayrollCalendar::Contract.new(pay_period).payload.merge(
      "schedule_version" => 1,
      "publication_id" => publication_id
    )
    calendar.publications.create!(
      created_by: admin,
      schedule_version: 1,
      publication_id: publication_id,
      payload: payload,
      payload_checksum: TimeTracking::CanonicalPayload.checksum(payload),
      delivery_status: "delivered",
      delivery_attempts: 1,
      last_delivery_attempt_at: now,
      delivered_at: now,
      source_state: payload.merge(
        "external_pay_period_id" => external_id,
        "status" => source_state,
        "cutoff_state" => source_state == "finalized" ? "finalized" : "upcoming"
      )
    )
    pay_period
  end

  build_period.call(id: 900_001, dates: manual_dates, source_state: "finalized")
  build_period.call(id: 900_002, dates: connected_dates, source_state: "scheduled")
end

puts "Seeded Cornerstone staging fixture: manual period #{manual_dates.join('..')}, connected period #{connected_dates.join('..')}"
