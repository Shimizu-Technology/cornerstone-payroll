# frozen_string_literal: true

unless Rails.env.production? &&
       ENV["DEPLOYMENT_ENV"] == "staging" &&
       ENV["STAGING_SEED_ALLOWED"] == "true" &&
       ENV["STAGING_FIXTURE_NAMESPACE"] == "staging-v2"
  abort "Refusing to seed outside the explicit Cornerstone staging v2 deployment"
end

database_name = ActiveRecord::Base.connection_db_config.database.to_s
abort "Refusing to seed an unexpected database" unless database_name == "cornerstone_payroll_staging_v2"

slug = "aire-payroll-staging-v2"
browser_origin = ENV.fetch("AIRE_PUBLIC_URL")
if (organization = Organization.find_by(slug: slug))
  # Keep existing payroll/history untouched. Only the known isolated fixture's
  # browser destination follows this stack's trusted HTTPS deployment config.
  source = TimeTrackingSource.find_by!(id: 910_001, company_id: 910_001,
    source_type: "aire_services", base_url: "http://aire-api:3000")
  abort "Unexpected staging fixture owner" unless source.company.organization_id == organization.id
  source.update!(authorization_origin: browser_origin) unless source.authorization_origin == browser_origin
  puts "Cornerstone staging v2 fixture already exists; browser destination verified"
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

periods = (-4..2).flat_map do |offset|
  reference = now.to_date.advance(months: offset)
  [ period_for.call(reference.change(day: 1)), period_for.call(reference.change(day: 16)) ]
end.uniq.sort_by(&:first)

pay_date_for = ->((_start_date, end_date)) { end_date.day == 15 ? end_date.end_of_month : end_date.next_month.change(day: 15) }
cutoff_for_index = lambda do |index|
  previous_pay_date = pay_date_for.call(periods.fetch(index - 1))
  cutoff_date = previous_pay_date + 7.days
  guam.local(cutoff_date.year, cutoff_date.month, cutoff_date.day, 17, 0)
end

manual_index = (1...(periods.length - 1)).find do |index|
  cutoff_for_index.call(index) <= now && cutoff_for_index.call(index + 1) > now
end
abort "No adjacent finalized and upcoming staging v2 periods are available" unless manual_index

context_dates = periods.fetch(manual_index - 1)
manual_dates = periods.fetch(manual_index)
connected_dates = periods.fetch(manual_index + 1)

admin_clerk_id = ENV.fetch("PAYROLL_STAGING_ADMIN_CLERK_ID")
admin_email = ENV.fetch("STAGING_ADMIN_EMAIL")
integration_secret = ENV.fetch("PAYROLL_SHARED_SECRET")

ActiveRecord::Base.transaction do
  organization = Organization.create!(
    id: 910_001,
    name: "AIRE + Cornerstone Staging v2",
    slug: slug,
    status: "active"
  )
  company = organization.companies.create!(
    id: 910_001,
    name: "Staging v2 Flight Operations",
    address_line1: "200 Test Flight Lane",
    city: "Hagåtña",
    state: "GU",
    zip: "96910",
    phone: "(671) 555-0299",
    email: "payroll-staging-v2@example.test",
    pay_frequency: "semimonthly",
    ein: "00-0000097"
  )
  organization.update!(primary_company: company)
  admin = User.create!(
    id: 910_001,
    organization: organization,
    company: company,
    clerk_id: admin_clerk_id,
    email: admin_email,
    name: "Chels Staging v2",
    role: "org_admin",
    invitation_status: "accepted",
    active: true
  )

  foundation_date = context_dates.first.beginning_of_year
  workweek = CompanyWorkweek.create!(
    company: company,
    starts_on_weekday: 0,
    starts_at_minutes: 0,
    timezone: "Pacific/Guam",
    source: "operator_confirmed",
    confirmation_status: "confirmed",
    confirmed_by: admin,
    confirmed_at: now,
    notes: "Confirmed for the isolated staging v2 workflow",
    effective_on: foundation_date
  )
  schedule = CompanyPaySchedule.create!(
    company: company,
    frequency: "semimonthly",
    period_rule: "semimonthly",
    pay_date_rule: "semimonthly_15th_and_month_end",
    timezone: "Pacific/Guam",
    source: "operator_confirmed",
    confirmation_status: "confirmed",
    confirmed_by: admin,
    confirmed_at: now,
    notes: "Confirmed for the isolated staging v2 workflow",
    effective_on: foundation_date,
    payroll_cutoff_days_before: 7,
    payroll_cutoff_at_minutes: 1_020,
    time_tracking_cutoff_rule: "after_previous_regular_payday",
    time_tracking_cutoff_days: 7
  )
  department = Department.create!(company: company, name: "Staging v2 Operations")

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
      hire_date: context_dates.first - 1.year,
      address_line1: "#{id - 910_000} Test Employee Lane",
      city: "Hagåtña",
      state: "GU",
      zip: "96910",
      payment_delivery_method: "paper_check"
    )
    EmployeeWageRate.create!(
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
          review_note: "Synthetic staging v2 employee; no real payroll or filing",
          lock_version: requirement.lock_version
        }
      ).call!
    end
    employee
  end

  ari = create_employee.call(
    id: 910_101,
    first_name: "Ari",
    last_name: "Reconciliation",
    email: "ari.reconciliation.v2@example.test",
    rate: 25,
    label: "Staging v2 Reconciliation",
    ssn: "910-00-0101"
  )
  casey = create_employee.call(
    id: 910_102,
    first_name: "Casey",
    last_name: "Connected",
    email: "casey.connected.v2@example.test",
    rate: 20,
    label: "Staging v2 Connected Operations",
    ssn: "910-00-0102"
  )

  source = TimeTrackingSource.create!(
    id: 910_001,
    company: company,
    name: "AIRE Staging v2",
    source_type: "aire_services",
    base_url: "http://aire-api:3000",
    authorization_origin: browser_origin,
    shared_secret: integration_secret,
    active: true
  )
  [
    [ ari, 910_101, "00000000-0000-4000-8000-000000000111" ],
    [ casey, 910_102, "00000000-0000-4000-8000-000000000112" ]
  ].each do |employee, source_user_id, source_user_uuid|
    TimeTrackingEmployeeMapping.create!(
      company: company,
      time_tracking_source: source,
      employee: employee,
      source_user_id: source_user_id.to_s,
      source_user_uuid: source_user_uuid
    )
  end

  build_period = lambda do |id:, dates:, publish:, source_state:|
    start_date, end_date = dates
    pay_period = PayPeriod.create!(
      id: id,
      company: company,
      company_pay_schedule: schedule,
      company_workweek: workweek,
      start_date: start_date,
      end_date: end_date,
      pay_date: pay_date_for.call(dates),
      status: "draft",
      cycle: "regular",
      run_purpose: "regular",
      run_purpose_source: "operator_selected",
      notes: "Synthetic staging v2 payroll; never production"
    )
    next pay_period unless publish

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

  build_period.call(id: 910_000, dates: context_dates, publish: false, source_state: nil)
  build_period.call(id: 910_001, dates: manual_dates, publish: true, source_state: "finalized")
  build_period.call(id: 910_002, dates: connected_dates, publish: true, source_state: "scheduled")
end

puts "Seeded Cornerstone staging v2 fixture: reconciliation period #{manual_dates.join('..')}, connected period #{connected_dates.join('..')}"
