# frozen_string_literal: true

# Optional synthetic history fixture for the existing real-HTTP certificate.
require "json"
raise "Synthetic test fixture only" unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" &&
  ActiveRecord::Base.connection_db_config.database.include?("_certification_rollout_rehearsal_")

aire = JSON.parse(File.read(ENV.fetch("AIRE_CERTIFICATION_FIXTURE_PATH")))
payroll = JSON.parse(File.read(ENV.fetch("CERTIFICATION_FIXTURE_PATH")))
if ENV.fetch("CERTIFICATION_STAGE2_APP") == "aire"
  admin = User.find_by!(email: "aire-certification-admin@example.test")
  admin.update!(email: payroll.fetch("admin_email"))
  PayrollAccountLink.create!(user: admin, external_system: "cornerstone_payroll", external_actor_id: payroll.fetch("history_actor_id").to_s,
    external_actor_email: payroll.fetch("admin_email"), linked_at: Time.current, active: true)
  employee = User.find(aire.fetch("employee_id"))
  category = TimeCategory.find_by!(key: "certification_operations")
  day = Date.iso8601(aire.fetch("start_date")) - 1.day
  from = day.day == 15 ? day.beginning_of_month : day.change(day: 16)
  build = lambda do |approval, hours|
    start = Time.find_zone!("Pacific/Guam").local(from.year, from.month, from.day, 8)
    entry = TimeEntry.create!(user: employee, time_category: category, work_date: from,
      start_time: start, end_time: start + hours.hours, break_minutes: 0, status: "completed", entry_method: "manual",
      approval_status: approval, approved_by: approval == "approved" ? admin : nil,
      approved_at: approval == "approved" ? 2.days.ago : nil, overtime_status: "none")
    entry.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    entry
  end
  baseline = build.call("approved", 2)
  batch = Payroll::BatchFinalizer.new(start_date: from, end_date: day, actor: admin, manual_processing: true,
    cutoff_at: 1.hour.ago.iso8601, processed_at: 30.minutes.ago.iso8601,
    external_pay_period_id: payroll.fetch("previous_pay_period_id"), processing_note: "Synthetic reviewed manual baseline; no delivery assertion").call
  pending = build.call("pending", 1)
  denied = build.call("denied", 1)
  zero = build.call("pending", 1)
  zero.update_column(:hours, 0)
  held = build.call("approved", 1)
  Payroll::PaymentAttestationRecorder.new(actor: admin).attest!(entry: held,
    source_user_uuid: employee.payroll_integration_uuid, reason: "Synthetic owner report; payment evidence intentionally remains pending")
  owed = build.call("approved", 4.25)
  Payroll::LegacyHistoryCaseReview.capture!(owed, actor: admin, reason: "Synthetic reviewed source is genuinely owed; preserve explicit routing")
  aire["history_entry_ids"] = [ baseline, pending, denied, zero, held, owed ].map(&:id)
  aire["history_batch_id"] = batch.public_id
  aire["history_pending_entry_id"] = pending.id
  aire["history_owed_entry_id"] = owed.id
  File.write(ENV.fetch("AIRE_CERTIFICATION_FIXTURE_PATH"), JSON.pretty_generate(aire))
else
  actor = User.find_by!(email: payroll.fetch("admin_email"))
  period = PayPeriod.find(payroll.fetch("previous_pay_period_id"))
  mapping = TimeTrackingSource.find(payroll.fetch("source_id")).time_tracking_employee_mappings.find_by!(source_user_uuid: aire.fetch("employee_uuid"))
  item = PayrollItem.create!(company: period.company, pay_period: period, employee: mapping.employee,
    hours_worked: 2, overtime_hours: 0, pay_rate: 25, gross_pay: 50, net_pay: 50, employment_type: mapping.employee.employment_type)
  item.calculate!(annual_fica_context: EmployeeYearFicaContext.new(employee: mapping.employee,
    year: period.pay_date.year, excluding_pay_period_id: period.id))
  period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: actor.id)
  lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
  lifecycle.approve!
  lifecycle.commit!
  TimeTrackingSource.find(payroll.fetch("source_id")).update!(historical_reconciliation_required: true)
  payroll["history_actor_id"] = actor.id
  File.write(ENV.fetch("CERTIFICATION_FIXTURE_PATH"), JSON.pretty_generate(payroll))
end
puts "PASS: seeded isolated synthetic historical coverage; no payment issued"
