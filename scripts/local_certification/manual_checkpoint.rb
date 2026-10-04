# frozen_string_literal: true

# Invoked only by the disposable HTTP drill, never application startup.
require "json"
require "digest"

database = ActiveRecord::Base.connection_db_config.database.to_s
unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" &&
       database.match?(/\A(?:aire_cornerstone|cornerstone_aire)_certification_\d+_\d+\z/)
  abort "Refusing manual checkpoints outside the isolated certification database"
end
directory = File.dirname(ENV.fetch("CERTIFICATION_CLOCK_FILE"))
stat = File.lstat(directory)
unless File.basename(directory).start_with?("cornerstone-aire-certification.") &&
       stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
  abort "Manual checkpoints require the private clock fixture"
end
result_path = ENV.fetch("MANUAL_RESULT_FILE")
unless File.dirname(result_path) == directory && !File.symlink?(result_path)
  abort "Manual results must remain in the private fixture"
end
payroll = JSON.parse(File.read(File.join(directory, "cornerstone.json")))
aire = JSON.parse(File.read(File.join(directory, "aire.json")))
action = ENV.fetch("MANUAL_ACTION")
result = case action
when "browser_profile"
  require_relative "manual_printer_fixture"
  period = PayPeriod.find(payroll.fetch("manual_browser_pay_period_id"))
  abort "Wrong browser company" unless period.company_id == payroll.fetch("company_id")
  profile = ManualPrinterFixture.seed!(company: period.company,
    accountant: User.find(payroll.fetch("manual_accountant_id")), admin: User.find_by!(email: payroll.fetch("admin_email")))
  { printer_profile_id: profile.id }
when "source_edit"
  entry = TimeEntry.find(aire.fetch("manual_entry_id"))
  abort "Wrong manual fixture identity" unless entry.user_id == aire.fetch("manual_employee_id")
  entry.update!(description: "Synthetic source version changed after accountant loaded it")
  { version: entry.lock_version }
when "remote_state", "browser_verify"
  rows = PayrollManualAllocation.where(time_entry_id: [aire.fetch("manual_entry_id"), aire.fetch("manual_void_entry_id"),
    aire.fetch("manual_browser_entry_id")]).order(:id)
  if action == "browser_verify"
    browser_rows = rows.select { |row| row.time_entry_id == aire.fetch("manual_browser_entry_id") }
    policy = JSON.parse(File.read(ENV.fetch("CERTIFICATION_POLICY_FIXTURE_PATH")))
    unless browser_rows.one? && browser_rows.first.status == "issued" && browser_rows.first.regular_hours == 4 &&
           browser_rows.first.overtime_hours.zero? && browser_rows.first.source_user_uuid == aire.fetch("manual_employee_uuid") &&
           browser_rows.first.external_pay_period_id == payroll.fetch("manual_browser_pay_period_id").to_s &&
           browser_rows.first.payment_effective_on&.iso8601 == policy.fetch("delivery_date") &&
           browser_rows.first.payment_reference.present? &&
           browser_rows.first.payroll_manual_allocation_events.order(:id).map(&:event_type) == %w[committed issued]
      abort "Browser manual source does not have one exact issued receipt"
    end
  end
  { allocations: rows.map do |row|
    { id: row.id, source_time_entry_id: row.time_entry_id.to_s, source_user_uuid: row.source_user_uuid,
      regular_hours: row.regular_hours.to_s("F"), overtime_hours: row.overtime_hours.to_s("F"),
      external_payroll_item_id: row.external_payroll_item_id,
      status: row.status, payment_reference: row.payment_reference,
      payment_effective_on: row.payment_effective_on&.iso8601,
      events: row.payroll_manual_allocation_events.order(:id).map(&:event_type) }
  end }
when "browser_payroll_verify"
  allocation = TimeTrackingManualAllocation.where(pay_period_id: payroll.fetch("manual_browser_pay_period_id")).sole
  item = allocation.payroll_item
  delivery = item.check_events.deliveries.where(check_number: item.check_number).order(:id).last
  unless item.pay_period.payroll_items.count == 1 && allocation.status == "issued" &&
         allocation.regular_hours == 4 && allocation.overtime_hours.zero? &&
         allocation.employee_id == payroll.fetch("manual_employee_id") &&
         allocation.source_time_entry_id == aire.fetch("manual_browser_entry_id").to_s &&
         allocation.source_user_uuid == aire.fetch("manual_employee_uuid") && delivery &&
         item.hours_worked == 4 && item.overtime_hours.zero?
    abort "Browser Payroll allocation/check does not match exact issued source hours"
  end
  { remote_allocation_id: allocation.remote_allocation_id, external_payroll_item_id: item.id.to_s,
    payment_reference: item.check_number, payment_effective_on: delivery.effective_on.iso8601 }
when "ambiguous_commit"
  actor = User.find(payroll.fetch("manual_accountant_id"))
  period = PayPeriod.find(payroll.fetch("manual_pay_period_ids").fetch(1))
  unless actor.accountant? && StaffRolePolicy.historical_reconciliation_allowed?(actor, period.company) &&
         !StaffRolePolicy.allowed?(actor, :manage_client_configuration)
    abort "The manual fixture must use an assigned accountant without configuration privileges"
  end
  request_path = ENV.fetch("MANUAL_REQUEST_FILE")
  abort "Manual requests must remain in the private fixture" unless File.dirname(request_path) == directory && !File.symlink?(request_path)
  request = JSON.parse(File.read(request_path)).symbolize_keys
  abort "Wrong manual source" unless request.fetch(:source_time_entry_id).to_s == aire.fetch("manual_entry_id").to_s
  # The real POST reaches AIRE and commits. Only its returned acknowledgement is
  # discarded in this short-lived test runner, modelling a lost response. Retry
  # must reuse the persisted command and recover AIRE's immutable receipt.
  TimeTracking::Client.prepend(Module.new do
    def commit_payroll_manual_allocation(**attributes)
      super
      raise TimeTracking::Client::Error, "Synthetic response lost after AIRE committed"
    end
  end)
  allocation = TimeTracking::ManualAllocationService.new(pay_period: period,
    source: TimeTrackingSource.find(payroll.fetch("source_id")), actor: actor).create!(**request)
  abort "Lost acknowledgement was not retained" unless allocation.status == "pending_commit" &&
    allocation.remote_allocation_id.nil? && allocation.last_sync_error == "Synthetic response lost after AIRE committed"
  { id: allocation.id, status: allocation.status, commit_command_id: allocation.commit_command_id }
when "sync"
  id = Integer(ENV.fetch("MANUAL_ALLOCATION_ID"), 10)
  allocation = TimeTrackingManualAllocation.find(id)
  abort "Wrong manual fixture allocation" unless payroll.fetch("manual_pay_period_ids").include?(allocation.pay_period_id)
  AireManualAllocationSyncJob.perform_now(id)
  { id: id, status: allocation.reload.status }
when "original_capture", "original_verify"
  snapshot = if database.start_with?("cornerstone_aire_")
    period = PayPeriod.find(payroll.fetch("pay_period_id"))
    { period: period.attributes, items: period.payroll_items.order(:id).map(&:attributes),
      imports: period.time_tracking_imports.order(:id).map(&:attributes) }
  else
    { batches: PayrollBatch.order(:id).map(&:attributes),
      entries: TimeEntry.where(id: [aire.fetch("ordinary_entry_id"), aire.fetch("approved_manual_entry_id"),
        aire.fetch("held_manual_entry_id")]).order(:id).map(&:attributes) }
  end
  digest = Digest::SHA256.hexdigest(JSON.generate(snapshot))
  path = File.join(directory, "manual-original-#{database.start_with?("cornerstone_aire_") ? 'payroll' : 'aire'}.json")
  if action == "original_capture"
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(digest: digest)) }
  else
    abort "Original connected evidence changed during manual certification" unless JSON.parse(File.read(path)).fetch("digest") == digest
  end
  { original_evidence_unchanged: true }
else
  abort "Unknown isolated manual checkpoint"
end
File.open(result_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  file.write(JSON.generate(result))
end
