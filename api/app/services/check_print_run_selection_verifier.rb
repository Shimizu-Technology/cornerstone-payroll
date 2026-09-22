# frozen_string_literal: true

class CheckPrintRunSelectionVerifier
  class StaleSelectionError < StandardError; end

  def initialize(run:, lock: false)
    @run = run
    @lock = lock
  end

  def call
    raise StaleSelectionError, "This pay period is no longer committed" unless run.pay_period.committed?

    payroll_items, non_employee_checks = load_current_records
    verify_manifest!(payroll_items, non_employee_checks)
    [ payroll_items, non_employee_checks ]
  end

  private

  attr_reader :run, :lock

  def load_current_records
    employee_ids = run.manifest.filter_map do |entry|
      entry.fetch("source_id") if entry.fetch("source_type") == "payroll_item"
    end
    non_employee_ids = run.manifest.filter_map do |entry|
      entry.fetch("source_id") if entry.fetch("source_type") == "non_employee_check"
    end

    payroll_scope = PayrollItem.where(id: employee_ids, pay_period_id: run.pay_period_id, company_id: run.company_id).includes(:employee)
    non_employee_scope = NonEmployeeCheck.where(id: non_employee_ids, pay_period_id: run.pay_period_id, company_id: run.company_id)
    payroll_scope = payroll_scope.lock if lock
    non_employee_scope = non_employee_scope.lock if lock
    [ payroll_scope.index_by(&:id), non_employee_scope.index_by(&:id) ]
  end

  def verify_manifest!(payroll_items, non_employee_checks)
    run.manifest.each do |entry|
      record = entry.fetch("source_type") == "payroll_item" ? payroll_items[entry.fetch("source_id")] : non_employee_checks[entry.fetch("source_id")]
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
          "Check ##{entry.fetch('check_number')} #{reason}. Generate a new package from the current check queue."
  end
end
