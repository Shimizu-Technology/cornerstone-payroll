# frozen_string_literal: true

require "json"
require "digest"

database = ActiveRecord::Base.connection_db_config.database.to_s
abort "Unsafe payment checkpoint database" unless Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" &&
  database.match?(/\A(?:aire_cornerstone|cornerstone_aire)_certification_\d+_\d+\z/)
directory = File.dirname(ENV.fetch("CERTIFICATION_CLOCK_FILE"))
stat = File.lstat(directory)
abort "Unsafe private payment checkpoint" unless stat.directory? && stat.uid == Process.uid &&
  (stat.mode & 0o077).zero? && File.basename(directory).start_with?("cornerstone-aire-certification.")
output = ENV.fetch("PAYMENT_RESULT_FILE")
abort "Unsafe payment checkpoint output" unless File.dirname(output) == directory && !File.symlink?(output)
payroll = JSON.parse(File.read(File.join(directory, "cornerstone.json")))
aire = JSON.parse(File.read(File.join(directory, "aire.json")))
selection_file = File.join(directory, "payment-candidates.json")
selection = File.exist?(selection_file) ? JSON.parse(File.read(selection_file)) : nil

def native_payment_state(item, allocation = nil)
  attributes = item.reload.attributes.except("updated_at", "lock_version", "check_number", "payment_delivery_method",
    "check_printed_at", "check_print_count", "check_prepared_at", "check_prepared_source_updated_at")
  { id: item.id, employee_id: item.employee_id, pay_period_id: item.pay_period_id,
    check_number: item.check_number, method: item.effective_payment_delivery_method,
    committed: item.pay_period.committed?, voided: item.voided?,
    financial_digest: Digest::SHA256.hexdigest(JSON.generate(attributes)),
    allocation_id: allocation&.id, allocation_status: allocation&.reload&.status,
    confirmation_count: DirectDepositPaymentConfirmation.where(payroll_item_id: item.id).count }
end

result = case ENV.fetch("PAYMENT_ACTION")
when "select"
  direct = PayPeriod.find(payroll.fetch("pay_period_id")).payroll_items.joins(:time_tracking_entry_allocations).distinct.order(:id).first!
  allocation = TimeTrackingManualAllocation.where(pay_period_id: payroll.fetch("manual_pay_period_ids").first,
    source_time_entry_id: aire.fetch("manual_entry_id").to_s, status: "issued").sole
  abort "Wrong payment checkpoint company" unless [direct.company_id, allocation.company_id].all? { |id| id == payroll.fetch("company_id") }
  { direct: native_payment_state(direct).merge(source_entry_ids: direct.time_tracking_entry_allocations.pluck(:source_time_entry_id)),
    manual: native_payment_state(allocation.payroll_item, allocation) }
when "native"
  { direct: native_payment_state(PayrollItem.find(selection.fetch("direct").fetch("id"))),
    manual: native_payment_state(PayrollItem.find(selection.fetch("manual").fetch("id")),
      TimeTrackingManualAllocation.find(selection.fetch("manual").fetch("allocation_id"))) }
when "flush"
  ids = selection.values.map { |row| row.fetch("id") }
  AirePayrollEntryAcknowledgement.undelivered.where(payroll_item_id: ids).order(:id).find_each do |ack|
    AirePayrollEntryStatusSyncJob.perform_now(ack.id)
  end
  allocation = TimeTrackingManualAllocation.find(selection.fetch("manual").fetch("allocation_id"))
  AireManualAllocationSyncJob.perform_now(allocation.id)
  abort "Undelivered payment checkpoint receipts" if AirePayrollEntryAcknowledgement.undelivered.where(payroll_item_id: ids).exists?
  abort "Pending manual cancellation" if allocation.reload.payment_cancellation_intent.present? || allocation.last_sync_error.present?
  { delivered: true }
when "source"
  direct = selection.fetch("direct")
  events = PayrollEntryProcessingEvent.where(external_payroll_item_id: direct.fetch("id").to_s).order(:id)
  rows = PayrollBatchEntry.where(source_time_entry_id: direct.fetch("source_entry_ids"))
  user = User.find(rows.first.source_user_id)
  evidence = Payroll::EmployeePeriodEvidence.new(user: user, params: { detail_per_page: 100 })
  period = rows.first.work_date.change(day: rows.first.work_date.day <= 15 ? 1 : 16).iso8601
  detail = evidence.call(period_id: period).fetch(:period)
  lines = detail.fetch(:coverage_lines).select { |line| line[:external_payroll_item_id].to_s == direct.fetch("id").to_s }
  abort "Missing direct frozen coverage" if lines.empty?
  manual = PayrollManualAllocation.find_by!(external_payroll_item_id: selection.fetch("manual").fetch("id").to_s,
    time_entry_id: aire.fetch("manual_entry_id"))
  { direct: { states: lines.map { |line| line.fetch(:coverage_state) }.uniq,
      hours: lines.sum { |line| line.fetch(:total_hours) }, statuses: events.pluck(:status),
      methods: lines.map { |line| line[:payment_method] }.uniq,
      row_digest: Digest::SHA256.hexdigest(JSON.generate(rows.order(:id).map { |row| row.attributes.except("updated_at", "lock_version") })) },
    manual: { status: manual.status, regular: manual.regular_hours.to_s, overtime: manual.overtime_hours.to_s,
      reference: manual.payment_reference, method: manual.payment_method,
      events: manual.payroll_manual_allocation_events.order(:id).pluck(:event_type) } }
else
  abort "Unknown payment checkpoint"
end
File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(result)) }
