# frozen_string_literal: true

class CheckPrintRunSelectionVerifier
  class StaleSelectionError < StandardError; end

  def initialize(run:, lock: false, current_records: nil)
    @run = run
    @lock = lock
    @current_records = current_records
  end

  def call
    raise StaleSelectionError, "This pay period is no longer committed" unless run.pay_period.committed?
    validate_manifest_references!

    payroll_items, non_employee_checks = current_records || load_current_records
    verify_manifest!(payroll_items, non_employee_checks)
    [ payroll_items, non_employee_checks ]
  end

  def self.load_current_records(runs:, lock: false)
    manifests = runs.flat_map(&:manifest)
    payroll_item_ids = source_ids(manifests, "payroll_item")
    non_employee_check_ids = source_ids(manifests, "non_employee_check")
    company_ids = runs.map(&:company_id).uniq
    pay_period_ids = runs.map(&:pay_period_id).uniq

    payroll_scope = PayrollItem.where(id: payroll_item_ids, pay_period_id: pay_period_ids, company_id: company_ids).includes(:employee)
    non_employee_scope = NonEmployeeCheck.where(id: non_employee_check_ids, pay_period_id: pay_period_ids, company_id: company_ids)
    payroll_scope = payroll_scope.lock if lock
    non_employee_scope = non_employee_scope.lock if lock
    [ payroll_scope.index_by(&:id), non_employee_scope.index_by(&:id) ]
  end

  def self.source_ids(manifests, source_type)
    manifests.filter_map do |entry|
      entry["source_id"] if entry.is_a?(Hash) && entry["source_type"] == source_type
    end
  end

  private_class_method :source_ids

  private

  attr_reader :run, :lock, :current_records

  def load_current_records
    self.class.load_current_records(runs: [ run ], lock: lock)
  end

  def validate_manifest_references!
    valid = run.manifest.is_a?(Array) && run.manifest.all? do |entry|
      entry.is_a?(Hash) && entry["source_type"].present? && entry["source_id"].present?
    end
    return if valid

    raise StaleSelectionError,
          "This saved package has an invalid check reference. Generate a new package from the current check queue."
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
