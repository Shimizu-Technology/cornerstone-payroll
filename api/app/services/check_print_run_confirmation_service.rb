# frozen_string_literal: true

class CheckPrintRunConfirmationService
  class StaleSelectionError < StandardError; end

  def initialize(run:, actor:, ip_address: nil)
    @run = run
    @actor = actor
    @ip_address = ip_address
  end

  def call
    result = nil

    CheckPrintRun.transaction do
      locked_run = CheckPrintRun.lock.find(run.id)
      if locked_run.confirmed?
        result = { run: locked_run, already_confirmed: true, marked_printed: 0 }
        next
      end

      locked_period = PayPeriod.lock.find(locked_run.pay_period_id)
      raise StaleSelectionError, "This pay period is no longer committed" unless locked_period.committed?

      payroll_items, non_employee_checks = load_current_records(locked_run)
      verify_manifest!(locked_run, payroll_items, non_employee_checks)

      payroll_items.values.each { |item| item.mark_printed!(user: actor, ip_address: ip_address) }
      non_employee_checks.values.each(&:mark_printed!)

      locked_run.update!(
        status: "confirmed",
        confirmed_at: Time.current,
        confirmed_by: actor
      )
      record_confirmation_audit!(locked_run, payroll_items.size, non_employee_checks.size)
      result = {
        run: locked_run,
        already_confirmed: false,
        marked_printed: payroll_items.size + non_employee_checks.size
      }
    end

    result
  end

  private

  attr_reader :run, :actor, :ip_address

  def load_current_records(locked_run)
    employee_ids = locked_run.manifest.filter_map do |entry|
      entry.fetch("source_id") if entry.fetch("source_type") == "payroll_item"
    end
    non_employee_ids = locked_run.manifest.filter_map do |entry|
      entry.fetch("source_id") if entry.fetch("source_type") == "non_employee_check"
    end

    payroll_items = PayrollItem
      .where(id: employee_ids, pay_period_id: locked_run.pay_period_id, company_id: locked_run.company_id)
      .includes(:employee)
      .lock
      .index_by(&:id)
    non_employee_checks = NonEmployeeCheck
      .where(id: non_employee_ids, pay_period_id: locked_run.pay_period_id, company_id: locked_run.company_id)
      .lock
      .index_by(&:id)

    [ payroll_items, non_employee_checks ]
  end

  def verify_manifest!(locked_run, payroll_items, non_employee_checks)
    locked_run.manifest.each do |entry|
      record = if entry.fetch("source_type") == "payroll_item"
        payroll_items[entry.fetch("source_id")]
      else
        non_employee_checks[entry.fetch("source_id")]
      end
      raise_stale!(entry, "was removed") unless record
      raise_stale!(entry, "was voided") if record.voided?
      raise_stale!(entry, "has a different check number") unless record.check_number.to_s == entry.fetch("check_number")
      raise_stale!(entry, "has a different amount") unless current_amount(record) == entry.fetch("amount").to_d
      raise_stale!(entry, "changed after this package was generated") unless record.updated_at.iso8601(6) == entry.fetch("source_updated_at")
      raise_stale!(entry, "has new print activity") unless current_print_count(record) == entry.fetch("print_count").to_i
      raise_stale!(entry, "has new print activity") unless current_printed_at(record) == entry["printed_at"]
    end
  end

  def current_amount(record)
    record.is_a?(PayrollItem) ? record.net_pay.to_d : record.amount.to_d
  end

  def current_print_count(record)
    record.is_a?(PayrollItem) ? record.check_print_count.to_i : record.print_count.to_i
  end

  def current_printed_at(record)
    value = record.is_a?(PayrollItem) ? record.check_printed_at : record.printed_at
    value&.iso8601(6)
  end

  def raise_stale!(entry, reason)
    raise StaleSelectionError,
          "Check ##{entry.fetch('check_number')} #{reason}. Refresh the print queue and generate a new package."
  end

  def record_confirmation_audit!(locked_run, employee_count, non_employee_count)
    AuditLog.record!(
      user: actor,
      organization_id: locked_run.company.organization_id,
      company_id: locked_run.company_id,
      action: "check_print_runs#confirmed",
      record_type: "check_print_runs",
      record_id: locked_run.id,
      subject_name: "Check package for #{locked_run.pay_period.start_date} through #{locked_run.pay_period.end_date}",
      metadata: {
        pay_period_id: locked_run.pay_period_id,
        selected_count: locked_run.selected_count,
        employee_check_count: employee_count,
        non_employee_check_count: non_employee_count,
        check_numbers: locked_run.manifest.map { |entry| entry.fetch("check_number") },
        starting_slot: locked_run.starting_slot,
        sha256: locked_run.sha256
      },
      ip_address: ip_address,
      event_category: "activity"
    )
  end
end
