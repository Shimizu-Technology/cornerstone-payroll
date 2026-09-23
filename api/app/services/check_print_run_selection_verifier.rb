# frozen_string_literal: true

class CheckPrintRunSelectionVerifier
  class StaleSelectionError < StandardError; end

  def initialize(run:, lock: false, current_records: nil, verify_render_inputs: true)
    @run = run
    @lock = lock
    @current_records = current_records
    @verify_render_inputs = verify_render_inputs
  end

  def call
    raise StaleSelectionError, "This pay period is no longer committed" unless run.pay_period.committed?
    validate_manifest_references!
    render_company = verify_current_calibration!

    payroll_items, non_employee_checks = current_records || load_current_records
    verify_manifest!(payroll_items, non_employee_checks, render_company)
    [ payroll_items, non_employee_checks ]
  end

  def self.load_current_records(runs:, lock: false)
    manifests = runs.flat_map(&:manifest)
    payroll_item_ids = source_ids(manifests, "payroll_item")
    non_employee_check_ids = source_ids(manifests, "non_employee_check")
    company_ids = runs.map(&:company_id).uniq
    pay_period_ids = runs.map(&:pay_period_id).uniq

    payroll_scope = PayrollItem
      .where(id: payroll_item_ids, pay_period_id: pay_period_ids, company_id: company_ids)
      .includes(:payroll_item_earnings, :payroll_item_field_entries,
                { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company })
    non_employee_scope = NonEmployeeCheck
      .where(id: non_employee_check_ids, pay_period_id: pay_period_ids, company_id: company_ids)
      .includes(:company, :pay_period, :line_items)
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

  attr_reader :run, :lock, :current_records, :verify_render_inputs

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

  def verify_manifest!(payroll_items, non_employee_checks, render_company)
    run.manifest.each do |entry|
      record = entry.fetch("source_type") == "payroll_item" ? payroll_items[entry.fetch("source_id")] : non_employee_checks[entry.fetch("source_id")]
      raise_stale!(entry, "was removed") unless record
      raise_stale!(entry, "was voided") if record.voided?
      raise_stale!(entry, "has a different check number") unless record.check_number.to_s == entry.fetch("check_number")
      raise_stale!(entry, "has a different amount") unless current_amount(record) == entry.fetch("amount").to_d
      raise_stale!(entry, "changed after this package was generated") unless record.updated_at.iso8601(6) == entry.fetch("source_updated_at")
      raise_stale!(entry, "has new print activity") unless current_print_count(record) == entry.fetch("print_count").to_i
      raise_stale!(entry, "has new print activity") unless current_printed_at(record) == entry["printed_at"]
      verify_render_input!(entry, record, render_company) if verify_render_inputs
    end
  end

  def verify_current_calibration!
    company = run.company
    if run.check_stock_type != company.check_stock_type
      raise StaleSelectionError,
        "The company check-stock type changed after this package was generated. Generate a replacement package."
    end

    settings = CheckRenderSettings.resolve(
      company: company,
      actor: run.created_by,
      printer_profile_id: run.printer_profile_id,
      require_profile: run.printer_profile_id.present?
    )
    stored_digest = run.calibration_snapshot["calibration_digest"]
    if stored_digest.present? && settings.calibration_digest != stored_digest
      raise StaleSelectionError,
        "Printer calibration changed after this package was generated. Generate a replacement package."
    end

    settings.apply_to(company)
  rescue CheckRenderSettings::MissingProfileError, CheckRenderSettings::IncompatibleProfileError
    raise StaleSelectionError,
      "The printer profile used for this package is no longer available. Generate a replacement package."
  end

  def verify_render_input!(entry, record, render_company)
    stored_digest = entry["render_input_digest"]
    return if stored_digest.blank? # Older packages keep the legacy verification contract.

    current_digest = CheckPrintRenderFingerprint.for_record(
      record,
      company: render_company,
      check_stock_type: run.check_stock_type
    )
    raise_stale!(entry, "has different rendered check or stub information") unless current_digest == stored_digest
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
