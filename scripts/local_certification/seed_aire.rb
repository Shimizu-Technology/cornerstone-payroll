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

  {
    schema_version: 1,
    integration_profile: Payroll::IntegrationProfile.call,
    shared_secret: shared_secret,
    delegation_token: grant.issued_token,
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
