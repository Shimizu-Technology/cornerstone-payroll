# frozen_string_literal: true

require "json"
require "securerandom"

database_name = ActiveRecord::Base.connection_db_config.database.to_s
unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" && database_name.start_with?("aire_cornerstone_certification_")
  abort "Refusing to seed outside an isolated AIRE certification test database"
end

output_path = ENV.fetch("CERTIFICATION_FIXTURE_PATH")
shared_secret = ENV.fetch("PAYROLL_SHARED_SECRET")
abort "The local certification secret is required" if shared_secret.blank?

populated = {
  users: User.count,
  time_categories: TimeCategory.count,
  time_entries: TimeEntry.count,
  payroll_calendar_periods: PayrollCalendarPeriod.count
}.reject { |_name, count| count.zero? }
abort "Refusing to seed a populated AIRE certification database: #{populated.inspect}" if populated.any?

guam = ActiveSupport::TimeZone["Pacific/Guam"]
policy = JSON.parse(File.read(ENV.fetch("CERTIFICATION_POLICY_FIXTURE_PATH")))
abort "Unsupported certification policy fixture" unless policy.fetch("schema_version") == 1
cutoff_at = Time.iso8601(policy.fetch("cutoff_at")).in_time_zone("Pacific/Guam")
pay_date = Date.iso8601(policy.fetch("pay_date"))
start_date = Date.iso8601(policy.fetch("start_date"))
end_date = Date.iso8601(policy.fetch("end_date"))
abort "Certification must begin before its fixed cutoff" unless (cutoff_at - Time.current).to_i == 120

fixture = ApplicationRecord.transaction do
  admin = User.create!(
    email: "aire-certification-admin@example.test",
    clerk_id: "aire_certification_admin",
    first_name: "Chels",
    last_name: "Certification",
    role: "admin",
    is_active: true,
    personal_access_enabled: true,
    profile_source: "clerk",
    time_tracking_enabled: false
  )
  employee = User.create!(
    email: "aire-certification-employee@example.test",
    clerk_id: "aire_certification_employee",
    first_name: "Ari",
    last_name: "Worker",
    role: "employee",
    is_active: true,
    personal_access_enabled: true,
    profile_source: "clerk",
    time_tracking_enabled: true,
    kiosk_enabled: true
  )
  category = TimeCategory.create!(
    name: "Certification Operations",
    key: "certification_operations",
    hourly_rate_cents: 2_500,
    is_active: true
  )
  UserTimeCategory.create!(user: employee, time_category: category, hourly_rate_cents: 2_500)

  timestamps = {
    created_at: cutoff_at - 2.days,
    updated_at: cutoff_at - 2.days
  }
  entry_attributes = {
    user: employee,
    time_category: category,
    work_date: start_date,
    status: "completed",
    overtime_status: "none",
    start_time: guam.local(start_date.year, start_date.month, start_date.day, 8, 0),
    end_time: guam.local(start_date.year, start_date.month, start_date.day, 16, 0),
    break_minutes: 0
  }
  ordinary = TimeEntry.create!(
    **entry_attributes,
    **timestamps,
    entry_method: "clock",
    clock_source: "kiosk",
    approval_status: nil,
    description: "Ordinary kiosk time"
  )
  manual_to_approve = TimeEntry.create!(
    **entry_attributes,
    **timestamps,
    entry_method: "manual",
    clock_source: "admin",
    approval_status: "pending",
    end_time: guam.local(start_date.year, start_date.month, start_date.day, 14, 0),
    description: "Manual time to approve before cutoff"
  )
  manual_to_hold = TimeEntry.create!(
    **entry_attributes,
    **timestamps,
    entry_method: "manual",
    clock_source: "admin",
    approval_status: "pending",
    start_time: guam.local((start_date + 1.day).year, (start_date + 1.day).month, (start_date + 1.day).day, 8, 0),
    end_time: guam.local((start_date + 1.day).year, (start_date + 1.day).month, (start_date + 1.day).day, 12, 0),
    work_date: start_date + 1.day,
    description: "Manual time intentionally held"
  )

  grant = PayrollIntegrationGrant.issue!(
    user: admin,
    capabilities: PayrollIntegrationGrant::CAPABILITIES
  )

  manual_admin = User.create!(email: "aire-manual-authority@example.test", clerk_id: "aire_manual_authority",
    first_name: "Manual", last_name: "Authority", role: "admin", is_active: true,
    personal_access_enabled: true, profile_source: "clerk", time_tracking_enabled: false)
  manual_employee = User.create!(email: "aire-manual-worker@example.test", clerk_id: "aire_manual_worker",
    first_name: "Morgan", last_name: "Manual", role: "employee", is_active: true,
    personal_access_enabled: true, profile_source: "clerk", time_tracking_enabled: true, kiosk_enabled: true)
  UserTimeCategory.create!(user: manual_employee, time_category: category, hourly_rate_cents: 2_500)
  # A genuine weekly crossing: 32 prior hours before a ten-hour
  # Thursday, entirely after the original batch period. No daily OT rule.
  manual_week_start = (end_date + 1.day).beginning_of_week(:sunday)
  manual_week_start += 7.days if manual_week_start <= end_date
  manual_date = manual_week_start + 4.days
  weekly_context = 4.times.map do |offset|
    day = manual_week_start + offset.days
    TimeEntry.create!(**entry_attributes, **timestamps, user: manual_employee,
      work_date: day, start_time: guam.local(day.year, day.month, day.day, 8),
      end_time: guam.local(day.year, day.month, day.day, 14, 30),
      entry_method: "clock", clock_source: "kiosk", approval_status: nil,
      description: "Synthetic six-and-a-half-hour weekly overtime context")
  end
  manual_entry = TimeEntry.create!(**entry_attributes, **timestamps, user: manual_employee,
    work_date: manual_date, start_time: guam.local(manual_date.year, manual_date.month, manual_date.day, 8),
    end_time: guam.local(manual_date.year, manual_date.month, manual_date.day, 18),
    entry_method: "manual", clock_source: "admin", approval_status: "approved", approved_by: manual_admin,
    approved_at: cutoff_at - 2.days, overtime_status: "approved", overtime_approved_by: manual_admin,
    overtime_approved_at: cutoff_at - 2.days, description: "Synthetic unbatched manual reconciliation source")
  # The two regular sources below add six hours to the 26-hour context.
  # Keep every source inside even February’s short second half.
  void_date = manual_week_start
  void_entry = TimeEntry.create!(**entry_attributes, **timestamps, user: manual_employee,
    work_date: void_date, start_time: guam.local(void_date.year, void_date.month, void_date.day, 8),
    end_time: guam.local(void_date.year, void_date.month, void_date.day, 10),
    entry_method: "manual", clock_source: "admin", approval_status: "approved", approved_by: manual_admin,
    approved_at: cutoff_at - 2.days, description: "Synthetic undelivered manual-check void source")
  browser_date = manual_week_start + 1.day
  browser_entry = TimeEntry.create!(**entry_attributes, **timestamps, user: manual_employee,
    work_date: browser_date, start_time: guam.local(browser_date.year, browser_date.month, browser_date.day, 8),
    end_time: guam.local(browser_date.year, browser_date.month, browser_date.day, 12),
    entry_method: "manual", clock_source: "admin", approval_status: "approved", approved_by: manual_admin,
    approved_at: cutoff_at - 2.days, description: "Untouched approved four-hour source reserved for browser acceptance")
  manual_grant = PayrollIntegrationGrant.issue!(user: manual_admin, capabilities: ["settlement_case_management"])

  {
    schema_version: 1,
    integration_profile: Payroll::IntegrationProfile.call,
    shared_secret: shared_secret,
    delegation_token: grant.issued_token,
    manual_delegation_token: manual_grant.issued_token,
    manual_authority_id: manual_admin.id,
    manual_employee_id: manual_employee.id,
    manual_employee_uuid: manual_employee.payroll_integration_uuid,
    manual_employee_email: manual_employee.email,
    manual_entry_id: manual_entry.id,
    manual_week_context_entry_ids: weekly_context.map(&:id),
    manual_void_entry_id: void_entry.id,
    manual_work_date: manual_date.iso8601,
    manual_void_work_date: void_date.iso8601,
    manual_browser_entry_id: browser_entry.id,
    manual_browser_work_date: browser_date.iso8601,
    admin_id: admin.id,
    employee_id: employee.id,
    employee_uuid: employee.payroll_integration_uuid,
    employee_email: employee.email,
    category_id: category.id,
    category_key: category.key,
    category_name: category.name,
    ordinary_entry_id: ordinary.id,
    approved_manual_entry_id: manual_to_approve.id,
    held_manual_entry_id: manual_to_hold.id,
    start_date: start_date.iso8601,
    end_date: end_date.iso8601,
    pay_date: pay_date.iso8601,
    cutoff_at: cutoff_at.iso8601
  }
end

File.write(output_path, JSON.pretty_generate(fixture))
puts "Seeded isolated AIRE certification fixture (secret and delegation token withheld)"
