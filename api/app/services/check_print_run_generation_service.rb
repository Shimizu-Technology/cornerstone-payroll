# frozen_string_literal: true

require "combine_pdf"
require "digest"

class CheckPrintRunGenerationService
  def initialize(pay_period:, actor:, payroll_item_ids:, non_employee_check_ids:, starting_slot:, ip_address: nil,
                 storage: R2StorageService.new)
    @pay_period = pay_period
    @actor = actor
    @payroll_item_ids = normalize_ids(payroll_item_ids)
    @non_employee_check_ids = normalize_ids(non_employee_check_ids)
    @starting_slot = Integer(starting_slot || 1)
    @ip_address = ip_address
    @storage = storage
  rescue ArgumentError, TypeError
    raise ArgumentError, "Starting slot must be a number from 1 through 4"
  end

  def call
    key = nil
    validate_request!
    run = nil

    PayPeriod.transaction do
      locked_period = PayPeriod.lock.find(pay_period.id)
      raise ArgumentError, "Checks are only available for committed pay periods" unless locked_period.committed?

      payroll_items = load_payroll_items(locked_period)
      non_employee_checks = load_non_employee_checks(locked_period)
      validate_scoped_selection!(payroll_items, non_employee_checks)
      validate_printable_records!(payroll_items, non_employee_checks)

      manifest = build_manifest(payroll_items, non_employee_checks)
      raise ArgumentError, "Select at least one printable check" if manifest.empty?

      # Keep rendering and storage inside this lock boundary intentionally. The immutable manifest must describe the
      # exact rows used by the PDF; releasing the locks before upload would allow a correction to make them diverge.
      pdf_bytes = render_pdf(payroll_items, non_employee_checks, manifest)
      artifact_id = SecureRandom.uuid
      key = storage_key(artifact_id)
      filename = print_run_filename(artifact_id)
      storage.upload(key, StringIO.new(pdf_bytes), content_type: "application/pdf")

      run = CheckPrintRun.create!(
        company: pay_period.company,
        pay_period: pay_period,
        created_by: actor,
        status: "generated",
        check_stock_type: pay_period.company.check_stock_type,
        starting_slot: effective_starting_slot,
        selected_count: manifest.size,
        manifest: manifest,
        storage_key: key,
        filename: filename,
        sha256: Digest::SHA256.hexdigest(pdf_bytes),
        byte_size: pdf_bytes.bytesize,
        generated_at: Time.current
      )

      record_generation_audit!(run, payroll_items, non_employee_checks)
    end

    run
  rescue StandardError
    cleanup_storage(key)
    raise
  end

  private

  attr_reader :pay_period, :actor, :payroll_item_ids, :non_employee_check_ids, :starting_slot, :ip_address, :storage

  def normalize_ids(values)
    Array(values).filter_map do |value|
      parsed = Integer(value)
      parsed if parsed.positive?
    rescue ArgumentError, TypeError
      nil
    end.uniq
  end

  def validate_request!
    raise ArgumentError, "Checks are only available for committed pay periods" unless pay_period.committed?
    raise ArgumentError, "Select at least one printable check" if payroll_item_ids.empty? && non_employee_check_ids.empty?
    raise ArgumentError, "Starting slot must be a number from 1 through 4" unless (1..4).cover?(starting_slot)
  end

  def load_payroll_items(locked_period)
    PayrollItem
      .where(id: payroll_item_ids, pay_period_id: locked_period.id, company_id: locked_period.company_id)
      .includes(:payroll_item_earnings, :payroll_item_field_entries,
                { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company })
      .lock
      .to_a
  end

  def load_non_employee_checks(locked_period)
    NonEmployeeCheck
      .where(id: non_employee_check_ids, pay_period_id: locked_period.id, company_id: locked_period.company_id)
      .includes(:company, :pay_period, :line_items)
      .lock
      .to_a
  end

  def validate_scoped_selection!(payroll_items, non_employee_checks)
    missing_employee = payroll_item_ids - payroll_items.map(&:id)
    missing_non_employee = non_employee_check_ids - non_employee_checks.map(&:id)
    return if missing_employee.empty? && missing_non_employee.empty?

    raise ArgumentError, "One or more selected checks do not belong to this pay period"
  end

  def validate_printable_records!(payroll_items, non_employee_checks)
    invalid_employee = payroll_items.find { |item| item.voided? || item.check_number.blank? || !item.net_pay.to_d.positive? }
    if invalid_employee
      raise ArgumentError, "Employee check ##{invalid_employee.check_number.presence || invalid_employee.id} is no longer printable"
    end

    invalid_non_employee = non_employee_checks.find { |check| check.voided? || check.check_number.blank? }
    if invalid_non_employee
      raise ArgumentError, "Non-employee check ##{invalid_non_employee.check_number.presence || invalid_non_employee.id} is no longer printable"
    end
  end

  def build_manifest(payroll_items, non_employee_checks)
    entries = payroll_items.map { |item| manifest_entry_for_payroll_item(item) }
    entries.concat(non_employee_checks.map { |check| manifest_entry_for_non_employee_check(check) })
    entries.sort_by { |entry| check_number_sort_key(entry.fetch("check_number"), entry.fetch("key")) }
  end

  def manifest_entry_for_payroll_item(item)
    {
      "key" => "payroll_item:#{item.id}",
      "source_type" => "payroll_item",
      "source_id" => item.id,
      "check_number" => item.check_number.to_s,
      "payee" => item.employee.full_name,
      "amount" => format("%.2f", item.net_pay.to_d),
      "source_updated_at" => item.updated_at.iso8601(6),
      "printed_at" => item.check_printed_at&.iso8601(6),
      "print_count" => item.check_print_count.to_i
    }
  end

  def manifest_entry_for_non_employee_check(check)
    {
      "key" => "non_employee_check:#{check.id}",
      "source_type" => "non_employee_check",
      "source_id" => check.id,
      "check_number" => check.check_number.to_s,
      "payee" => check.payable_to,
      "amount" => format("%.2f", check.amount.to_d),
      "source_updated_at" => check.updated_at.iso8601(6),
      "printed_at" => check.printed_at&.iso8601(6),
      "print_count" => check.print_count.to_i
    }
  end

  def render_pdf(payroll_items, non_employee_checks, manifest)
    if pay_period.company.first_hawaiian_4up_checks?
      return FirstHawaiianFourUpCheckGenerator.new(
        company: pay_period.company,
        payroll_items: payroll_items,
        non_employee_checks: non_employee_checks,
        starting_slot: effective_starting_slot
      ).generate
    end

    employee_by_id = payroll_items.index_by(&:id)
    non_employee_by_id = non_employee_checks.index_by(&:id)
    pdfs = manifest.map do |entry|
      if entry.fetch("source_type") == "payroll_item"
        CheckGenerator.new(employee_by_id.fetch(entry.fetch("source_id"))).generate
      else
        NonEmployeeCheckGenerator.new(non_employee_by_id.fetch(entry.fetch("source_id"))).generate
      end
    end
    combine_pdfs(pdfs)
  end

  def combine_pdfs(pdf_binaries)
    return pdf_binaries.first if pdf_binaries.one?

    combined = CombinePDF.new
    pdf_binaries.each { |data| combined << CombinePDF.parse(data) }
    combined.to_pdf
  rescue StandardError => e
    raise ArgumentError, "Failed to merge check PDFs: #{e.message}"
  end

  def effective_starting_slot
    pay_period.company.first_hawaiian_4up_checks? ? starting_slot : 1
  end

  def check_number_sort_key(check_number, fallback)
    value = check_number.to_s
    value.match?(/\A\d+\z/) ? [ 0, value.to_i, value, fallback ] : [ 1, 0, value.downcase, fallback ]
  end

  def storage_key(artifact_id)
    "check-print-runs/company-#{pay_period.company_id}/pay-period-#{pay_period.id}/#{artifact_id}.pdf"
  end

  def print_run_filename(artifact_id)
    pay_date = pay_period.pay_date&.strftime("%Y-%m-%d") || "undated"
    "check_run_#{pay_date}_#{artifact_id}.pdf"
  end

  def record_generation_audit!(run, payroll_items, non_employee_checks)
    AuditLog.record!(
      user: actor,
      organization_id: pay_period.company.organization_id,
      company_id: pay_period.company_id,
      action: "check_print_runs#generated",
      record_type: "check_print_runs",
      record_id: run.id,
      subject_name: "Check package for #{pay_period.start_date} through #{pay_period.end_date}",
      metadata: {
        pay_period_id: pay_period.id,
        selected_count: run.selected_count,
        employee_check_count: payroll_items.size,
        non_employee_check_count: non_employee_checks.size,
        check_numbers: run.manifest.map { |entry| entry.fetch("check_number") },
        starting_slot: run.starting_slot,
        sha256: run.sha256,
        ip_address: ip_address
      }.compact,
      ip_address: ip_address,
      event_category: "export"
    )
  end

  def cleanup_storage(key)
    return if key.blank?

    storage.delete(key)
  rescue StandardError => e
    Rails.logger.warn("Check print artifact cleanup failed: #{e.class}: #{e.message}")
  end
end
