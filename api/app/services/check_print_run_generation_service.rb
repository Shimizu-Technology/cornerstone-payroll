# frozen_string_literal: true

require "combine_pdf"
require "digest"

class CheckPrintRunGenerationService
  class InvalidSelectionError < StandardError; end
  class PdfAssemblyError < StandardError; end

  def initialize(pay_period:, actor:, payroll_item_ids:, non_employee_check_ids:, starting_slot:, ip_address: nil,
                 printer_profile_id:, printer_profile_lock_version:, storage: R2StorageService.new,
                 generation: nil, generation_worker_job_id: nil, progress: nil)
    @pay_period = pay_period
    @actor = actor
    @payroll_item_ids = normalize_ids(payroll_item_ids)
    @non_employee_check_ids = normalize_ids(non_employee_check_ids)
    @starting_slot = Integer(starting_slot || 1)
    @ip_address = ip_address
    @printer_profile_id = printer_profile_id
    @printer_profile_lock_version = printer_profile_lock_version
    @storage = storage
    @generation = generation
    @generation_worker_job_id = generation_worker_job_id
    @progress = progress
  rescue ArgumentError, TypeError
    raise ArgumentError, "Starting slot must be a number from 1 through 4"
  end

  def call
    key = nil
    validate_request!
    notify_progress("validating", 0)

    render_settings = resolve_render_settings(pay_period.company)
    render_company = render_settings.apply_to(pay_period.company)
    payroll_items = load_payroll_items(pay_period, lock: false)
    non_employee_checks = load_non_employee_checks(pay_period, lock: false)
    validate_scoped_selection!(payroll_items, non_employee_checks)
    validate_printable_records!(payroll_items, non_employee_checks)
    manifest = build_manifest(payroll_items, non_employee_checks)
    raise InvalidSelectionError, "Select at least one printable check" if manifest.empty?

    notify_progress("rendering", 0)
    pdf_bytes, render_digests = render_pdf(payroll_items, non_employee_checks, manifest, render_company)
    manifest.each { |entry| entry["render_input_digest"] = render_digests.fetch(entry.fetch("key")) }

    artifact_id = SecureRandom.uuid
    key = storage_key(artifact_id)
    filename = print_run_filename(artifact_id)
    sha256 = Digest::SHA256.hexdigest(pdf_bytes)

    notify_progress("uploading", manifest.size)
    storage.upload(key, StringIO.new(pdf_bytes), content_type: "application/pdf")
    notify_progress("verifying", manifest.size)
    verify_uploaded_artifact!(key, sha256, pdf_bytes.bytesize)

    finalize_run!(
      render_settings: render_settings,
      manifest: manifest,
      storage_key: key,
      filename: filename,
      sha256: sha256,
      byte_size: pdf_bytes.bytesize
    )
  rescue StandardError
    cleanup_storage(key)
    raise
  end

  private

  attr_reader :pay_period, :actor, :payroll_item_ids, :non_employee_check_ids, :starting_slot, :ip_address,
    :printer_profile_id, :printer_profile_lock_version, :storage, :generation, :generation_worker_job_id, :progress

  def notify_progress(phase, completed_items = nil)
    progress&.call(phase, completed_items)
  end

  def resolve_render_settings(company, lock_profile: false)
    CheckRenderSettings.resolve(
      company: company,
      actor: actor,
      printer_profile_id: printer_profile_id,
      printer_profile_lock_version: printer_profile_lock_version,
      require_profile: true,
      lock_profile: lock_profile
    )
  end

  def normalize_ids(values)
    Array(values).filter_map do |value|
      parsed = Integer(value)
      parsed if parsed.positive?
    rescue ArgumentError, TypeError
      nil
    end.uniq
  end

  def validate_request!
    raise InvalidSelectionError, "Checks are only available for committed pay periods" unless pay_period.committed?
    raise InvalidSelectionError, "Select at least one printable check" if payroll_item_ids.empty? && non_employee_check_ids.empty?
    raise InvalidSelectionError, "Starting slot must be a number from 1 through 4" unless (1..4).cover?(starting_slot)
    if printer_profile_id.blank? || printer_profile_lock_version.blank?
      raise InvalidSelectionError, "Choose a printer profile and refresh its calibration before generating checks"
    end
  end

  def load_payroll_items(period, lock:)
    scope = PayrollItem
      .where(id: payroll_item_ids, pay_period_id: period.id, company_id: period.company_id)
      .includes(:payroll_item_earnings, :payroll_item_field_entries,
                { payroll_item_deductions: :deduction_type, employee: :department, pay_period: :company })
    scope = scope.lock if lock
    scope.to_a
  end

  def load_non_employee_checks(period, lock:)
    scope = NonEmployeeCheck
      .where(id: non_employee_check_ids, pay_period_id: period.id, company_id: period.company_id)
      .includes(:company, :pay_period, :line_items)
    scope = scope.lock if lock
    scope.to_a
  end

  def validate_scoped_selection!(payroll_items, non_employee_checks)
    missing_employee = payroll_item_ids - payroll_items.map(&:id)
    missing_non_employee = non_employee_check_ids - non_employee_checks.map(&:id)
    return if missing_employee.empty? && missing_non_employee.empty?

    raise InvalidSelectionError, "One or more selected checks do not belong to this pay period"
  end

  def validate_printable_records!(payroll_items, non_employee_checks)
    invalid_employee = payroll_items.find { |item| item.voided? || item.check_number.blank? || !item.net_pay.to_d.positive? }
    if invalid_employee
      raise InvalidSelectionError, "Employee check ##{invalid_employee.check_number.presence || invalid_employee.id} is no longer printable"
    end

    invalid_non_employee = non_employee_checks.find { |check| check.voided? || check.check_number.blank? }
    if invalid_non_employee
      raise InvalidSelectionError, "Non-employee check ##{invalid_non_employee.check_number.presence || invalid_non_employee.id} is no longer printable"
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

  def render_pdf(payroll_items, non_employee_checks, manifest, render_company)
    if render_company.first_hawaiian_4up_checks?
      generator = FirstHawaiianFourUpCheckGenerator.new(
        company: render_company,
        payroll_items: payroll_items,
        non_employee_checks: non_employee_checks,
        starting_slot: effective_starting_slot(render_company.check_stock_type)
      )
      pdf = generator.generate
      notify_progress("rendering", manifest.size)
      notify_progress("assembling", manifest.size)
      digests = generator.render_input_payloads.transform_values do |payload|
        CheckPrintRenderFingerprint.for_payload(payload)
      end
      return [ pdf, digests ]
    end

    employee_by_id = payroll_items.index_by(&:id)
    non_employee_by_id = non_employee_checks.index_by(&:id)
    digests = {}
    pdfs = manifest.each_with_index.map do |entry, index|
      generator = if entry.fetch("source_type") == "payroll_item"
        CheckGenerator.new(employee_by_id.fetch(entry.fetch("source_id")), company: render_company)
      else
        NonEmployeeCheckGenerator.new(non_employee_by_id.fetch(entry.fetch("source_id")), company: render_company)
      end
      pdf = generator.generate
      digests[entry.fetch("key")] = CheckPrintRenderFingerprint.for_payload(generator.render_input_payload)
      notify_progress("rendering", index + 1)
      pdf
    end
    notify_progress("assembling", manifest.size)
    [ combine_pdfs(pdfs), digests ]
  end

  def verify_uploaded_artifact!(key, expected_sha256, expected_byte_size)
    stored = storage.download(key)
    unless stored && stored.bytesize == expected_byte_size && Digest::SHA256.hexdigest(stored) == expected_sha256
      raise R2StorageService::UploadError, "The saved check package failed its integrity check"
    end
  end

  def finalize_run!(render_settings:, manifest:, storage_key:, filename:, sha256:, byte_size:)
    run = nil

    PayPeriod.transaction do
      locked_period = PayPeriod.lock.find(pay_period.id)
      locked_generation = CheckPrintGeneration.lock.find(generation.id) if generation
      locked_generation&.assert_worker_lease!(job_id: generation_worker_job_id)
      raise InvalidSelectionError, "Checks are only available for committed pay periods" unless locked_period.committed?

      current_settings = resolve_render_settings(locked_period.company, lock_profile: true)
      unless current_settings.calibration_digest == render_settings.calibration_digest
        raise CheckPrintRunSelectionVerifier::StaleSelectionError,
          "Printer calibration changed while this package was generated. Review it and generate a replacement package."
      end

      payroll_items = load_payroll_items(locked_period, lock: true)
      non_employee_checks = load_non_employee_checks(locked_period, lock: true)
      validate_scoped_selection!(payroll_items, non_employee_checks)
      validate_printable_records!(payroll_items, non_employee_checks)

      run = CheckPrintRun.create!(
        company: locked_period.company,
        pay_period: locked_period,
        created_by: actor,
        printer_profile: current_settings.printer_profile,
        status: "generated",
        check_stock_type: current_settings.check_stock_type,
        starting_slot: effective_starting_slot(current_settings.check_stock_type),
        selected_count: manifest.size,
        manifest: manifest,
        calibration_snapshot: current_settings.snapshot,
        storage_key: storage_key,
        filename: filename,
        sha256: sha256,
        byte_size: byte_size,
        generated_at: Time.current
      )

      CheckPrintRunSelectionVerifier.new(
        run: run,
        current_records: [ payroll_items.index_by(&:id), non_employee_checks.index_by(&:id) ]
      ).call
      locked_generation&.complete_with!(run, job_id: generation_worker_job_id)
      record_generation_audit!(run, payroll_items, non_employee_checks)
    end

    run
  end

  def combine_pdfs(pdf_binaries)
    return pdf_binaries.first if pdf_binaries.one?

    combined = CombinePDF.new
    pdf_binaries.each { |data| combined << CombinePDF.parse(data) }
    combined.to_pdf
  rescue StandardError => e
    Rails.logger.error("[CheckPrintRunGenerationService] PDF assembly failed: #{e.class}: #{e.message}")
    raise PdfAssemblyError, "The package PDF could not be assembled"
  end

  def effective_starting_slot(stock_type)
    stock_type == "first_hawaiian_4up" ? starting_slot : 1
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
        printer_profile_id: run.printer_profile_id,
        printer_profile_name: run.calibration_snapshot["printer_profile_name"],
        printer_profile_lock_version: run.calibration_snapshot["printer_profile_lock_version"],
        calibration_digest: run.calibration_snapshot["calibration_digest"],
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
