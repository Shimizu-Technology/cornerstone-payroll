# frozen_string_literal: true

require "digest"
require "tempfile"

module QuickbooksHistory
  class CutoverVerificationService
    class StaleVerificationAttempt < StandardError; end

    SUPPORTED_RECORDED_IMPORTER_VERSIONS = %w[
      quickbooks-online-payroll-v2
      quickbooks-online-payroll-v3
      quickbooks-online-payroll-v4
    ].freeze
    LEGACY_WORKER_SNAPSHOT_IMPORTER_VERSIONS = %w[
      quickbooks-online-payroll-v2
      quickbooks-online-payroll-v3
    ].freeze
    WORKER_FIELDS = %i[external_key source_name normalized_name source_status hire_date].freeze
    PERIOD_FIELDS = %i[external_key period_type start_date end_date pay_date source_label paycheck_count totals].freeze
    PAYCHECK_FIELDS = %i[
      external_key source_row_number source_employee_name normalized_name pay_date period_start period_end
      period_type payment_method check_number source_status reconciliation_status hours_total hours_breakdown
      earnings_breakdown pretax_deduction_breakdown after_tax_deduction_breakdown employee_tax_breakdown
      employer_tax_breakdown employer_contribution_breakdown source_metadata
    ].concat(ImportService::MONEY_FIELDS).freeze

    Result = Struct.new(:review, :passed, keyword_init: true)

    def self.ensure_supported_importer_version!(version)
      return if version.in?(SUPPORTED_RECORDED_IMPORTER_VERSIONS)

      raise ArgumentError,
            "Importer version #{version.inspect} is unsupported. Preserve this batch and use an explicitly reviewed source migration."
    end

    def initialize(batch:, actor:, storage: R2StorageService.new, expected_verification_started_at: nil)
      @batch = batch
      @actor = actor
      @storage = storage
      @expected_verification_started_at = expected_verification_started_at
      @tempfiles = []
    end

    def call
      ensure_eligible!
      parsed = reparse_retained_sources!
      checks = build_checks(parsed)
      evidence = build_evidence(parsed, checks)
      review = persist_review!(evidence)
      Result.new(review: review, passed: evidence.fetch("passed"))
    ensure
      tempfiles.each(&:close!)
    end

    private

    attr_reader :batch, :actor, :storage, :tempfiles, :expected_verification_started_at

    def ensure_eligible!
      authorized = actor&.payroll_access_allowed? && actor.can_access_company?(batch.company_id) &&
        StaffRolePolicy.allowed?(actor, :manage_client_configuration)
      raise ArgumentError, "A manager or administrator with company access is required" unless authorized

      raise ArgumentError, "Apply the historical import before verifying cutover readiness" unless batch.applied?
      self.class.ensure_supported_importer_version!(batch.importer_version)
      if batch.historical_import_cutover_review&.approved?
        raise ArgumentError, "The approved cutover review is sealed"
      end
      ensure_current_attempt!(batch.historical_import_cutover_review) if expected_verification_started_at
    end

    def reparse_retained_sources!
      verifier = SourceFileVerificationService.new(batch: batch, actor: actor, storage: storage, audit: false)
      sources = batch.historical_import_source_files.in_manifest_order.map do |source_file|
        bytes = verifier.verified_bytes!(source_file)
        tempfile = Tempfile.new([ "historical-cutover-", File.extname(source_file.original_filename) ])
        tempfile.binmode
        tempfile.write(bytes)
        tempfile.flush
        tempfiles << tempfile
        BundleParser::SourceFile.new(
          original_filename: source_file.original_filename,
          path: tempfile.path,
          size: bytes.bytesize,
          content_type: source_file.content_type,
          source: tempfile
        )
      end
      raise ArgumentError, "Every retained QuickBooks source file must pass integrity verification" unless batch.reload.source_files_complete_and_verified?

      BundleParser.new(files: sources).call
    rescue R2StorageService::DownloadError, R2StorageService::ConfigurationError
      raise ArgumentError, "Retained QuickBooks source files could not be restored and verified"
    end

    def build_checks(parsed)
      stored_summary = canonical(batch.preview_summary)
      fresh_summary = canonical(parsed.summary)
      stored_reconciliation = canonical(batch.reconciliation_summary)
      fresh_reconciliation = canonical(parsed.reconciliation)
      stored_years = stored_year_totals
      fresh_years = parsed_year_totals(parsed.paychecks)
      digests = ledger_digests(parsed)

      [
        check("source_bundle", "Retained originals reproduce the recorded bundle", parsed.bundle_digest == batch.bundle_digest),
        check("importer_version", "The recorded importer version is supported by this verification parser", batch.importer_version.in?(SUPPORTED_RECORDED_IMPORTER_VERSIONS)),
        check("source_manifest", "Fresh file classifications match the retained source manifest", canonical(parsed.manifest) == canonical(batch.source_file_manifest)),
        check("source_reconciliation", "Fresh QuickBooks cross-report reconciliation passes", parsed.errors.empty? && fresh_reconciliation["passed"] == true),
        check("preview_contract", "Fresh source summary matches the staged preview", fresh_summary == stored_summary),
        check("reconciliation_contract", "Fresh reconciliation matches the staged reconciliation", fresh_reconciliation == stored_reconciliation),
        check("warning_contract", "Fresh source limitations match the staged review", canonical(parsed.warnings) == canonical(batch.warnings)),
        check("stored_counts", "Stored worker, period, and paycheck counts match the retained originals", stored_counts == source_counts(parsed)),
        check("stored_totals", "Stored payroll totals match the retained originals to the cent", stored_money_totals == fresh_summary.fetch("totals")),
        check("year_totals", "Every source pay year matches stored count and money totals", stored_years == fresh_years),
        check("worker_ledger", "Every stored worker source fact matches the retained originals", digests.dig("workers", "stored") == digests.dig("workers", "source")),
        check("period_ledger", "Every stored pay-period source fact matches the retained originals", digests.dig("periods", "stored") == digests.dig("periods", "source")),
        check("paycheck_ledger", "Every stored paycheck and component matches the retained originals", digests.dig("paychecks", "stored") == digests.dig("paychecks", "source")),
        check("worker_review", "Every QuickBooks worker has a reviewed link or archive-only decision", batch.unresolved_worker_count.zero?),
        check("source_files", "Every original source file is retained and verified", batch.source_files_complete_and_verified?)
      ]
    end

    def check(key, label, passed)
      { "key" => key, "label" => label, "passed" => passed }
    end

    def build_evidence(parsed, checks)
      {
        "version" => 1,
        "generated_at" => Time.current.iso8601(6),
        "passed" => checks.all? { |entry| entry.fetch("passed") },
        "batch_id" => batch.id,
        "bundle_digest" => batch.bundle_digest,
        "importer_version" => batch.importer_version,
        "verification_parser_version" => BundleParser::IMPORTER_VERSION,
        "checks" => checks,
        "counts" => stored_counts,
        "totals" => stored_money_totals,
        "years" => stored_year_totals.map { |year, values| values.merge("year" => year) },
        "ledger_digests" => ledger_digests(parsed),
        "source_files" => batch.historical_import_source_files.in_manifest_order.map do |source_file|
          {
            "filename" => source_file.original_filename,
            "sha256" => source_file.sha256,
            "byte_size" => source_file.byte_size,
            "report_type" => source_file.report_type,
            "verified" => source_file.verified?
          }
        end,
        "exceptions" => Array(batch.warnings).map do |warning|
          { "key" => Digest::SHA256.hexdigest(warning.to_s), "message" => warning.to_s }
        end,
        "fresh_source_label" => parsed.source_label
      }
    end

    def persist_review!(evidence)
      batch.with_lock do
        batch.reload
        review = batch.historical_import_cutover_review || batch.build_historical_import_cutover_review(company: batch.company)
        raise ArgumentError, "The approved cutover review is sealed" if review.approved?
        ensure_current_attempt!(review) if expected_verification_started_at

        exception_keys = evidence.fetch("exceptions").pluck("key")
        dispositions = review.exception_dispositions.to_h.slice(*exception_keys)
        passed = evidence.fetch("passed")
        review.assign_attributes(
          status: passed ? "verified" : "failed",
          evidence: evidence,
          evidence_digest: Digest::SHA256.hexdigest(JSON.generate(evidence)),
          verified_at: passed ? Time.current : nil,
          verified_by: passed ? actor : nil,
          verification_started_at: review.verification_started_at || Time.current,
          verification_error: nil,
          exception_dispositions: dispositions,
          approval_notes: nil,
          approval_acknowledgement: nil,
          approved_at: nil,
          approved_by: nil
        )
        review.save!
        record_audit!(review)
        review
      end
    end

    def ensure_current_attempt!(review)
      current_token = review&.verification_started_at&.iso8601(6)
      return if review&.pending? && current_token == expected_verification_started_at

      raise StaleVerificationAttempt, "A newer cutover verification attempt superseded this job"
    end

    def stored_counts
      @stored_counts ||= {
        "worker_count" => batch.historical_workers.count,
        "period_count" => batch.historical_pay_periods.count,
        "paycheck_count" => batch.historical_paychecks.count
      }
    end

    def source_counts(parsed)
      {
        "worker_count" => parsed.workers.size,
        "period_count" => parsed.periods.size,
        "paycheck_count" => parsed.paychecks.size
      }
    end

    def stored_money_totals
      @stored_money_totals ||= ImportService::MONEY_FIELDS.to_h do |field|
        [ field.to_s, batch.historical_paychecks.sum(field).to_d.round(2).to_s("F") ]
      end
    end

    def stored_year_totals
      stored_paycheck_verification.fetch("years")
    end

    def ledger_digests(parsed)
      @ledger_digests ||= {
        "workers" => {
          "source" => row_digest(parsed.workers.map { |row| source_worker_payload(row) }),
          "stored" => row_digest(batch.historical_workers.map { |row| stored_worker_payload(row) })
        },
        "periods" => {
          "source" => row_digest(parsed.periods.map { |row| select_payload(row, PERIOD_FIELDS) }),
          "stored" => row_digest(batch.historical_pay_periods.map { |row| select_payload(row, PERIOD_FIELDS) })
        },
        "paychecks" => {
          "source" => row_digest(parsed.paychecks) { |row| select_payload(row, PAYCHECK_FIELDS) },
          "stored" => stored_paycheck_verification.fetch("digest")
        }
      }
    end

    def stored_paycheck_verification
      @stored_paycheck_verification ||= begin
        years = Hash.new { |hash, year| hash[year] = empty_year_totals }
        relation = batch.historical_paychecks.includes(:historical_worker, :historical_pay_period)
        rows = relation.find_each(cursor: %i[external_key id], order: %i[asc asc], batch_size: 1_000)
        digest = ordered_row_digest(rows) do |row|
          accumulate_year_totals!(years[row.pay_date.year], row)
          stored_paycheck_payload(row)
        end
        {
          "years" => years.sort.to_h.transform_keys(&:to_s).transform_values { |totals| finalized_year_totals(totals) },
          "digest" => digest
        }
      end
    end

    def empty_year_totals
      {
        "paycheck_count" => 0,
        "detailed_paycheck_count" => 0,
        "opening_summary_count" => 0,
        "totals" => ImportService::MONEY_FIELDS.to_h { |field| [ field.to_s, 0.to_d ] }
      }
    end

    def accumulate_year_totals!(totals, row)
      totals["paycheck_count"] += 1
      period_type = row_period_type(row)
      totals["detailed_paycheck_count"] += 1 if period_type == "regular"
      totals["opening_summary_count"] += 1 if period_type == "opening_summary"
      ImportService::MONEY_FIELDS.each do |field|
        totals.fetch("totals")[field.to_s] += row_value(row, field).to_d
      end
    end

    def finalized_year_totals(totals)
      totals.merge(
        "totals" => totals.fetch("totals").transform_values { |value| value.round(2).to_s("F") }
      )
    end

    def source_worker_payload(row)
      snapshot = row.fetch(:private_snapshot)
      snapshot = snapshot.except("_employee_directory") if legacy_worker_snapshot?
      select_payload(row, WORKER_FIELDS).merge("private_snapshot" => snapshot)
    end

    def stored_worker_payload(row)
      select_payload(row, WORKER_FIELDS).merge("private_snapshot" => row.private_snapshot_data)
    end

    def legacy_worker_snapshot?
      batch.importer_version.in?(LEGACY_WORKER_SNAPSHOT_IMPORTER_VERSIONS)
    end

    def stored_paycheck_payload(row)
      select_payload(row, PAYCHECK_FIELDS - %i[normalized_name period_type]).merge(
        "normalized_name" => row.historical_worker.normalized_name,
        "period_type" => row.historical_pay_period.period_type
      )
    end

    def select_payload(row, fields)
      fields.to_h do |field|
        value = row.respond_to?(field) ? row.public_send(field) : row.fetch(field)
        [ field.to_s, value ]
      end
    end

    def row_digest(rows, &payload)
      ordered = rows.sort_by do |row|
        row.respond_to?(:external_key) ? row.external_key : row.fetch(:external_key) { row.fetch("external_key") }
      end
      ordered_row_digest(ordered, &payload)
    end

    def ordered_row_digest(rows)
      digest = Digest::SHA256.new
      digest << "["
      rows.each_with_index do |row, index|
        payload = block_given? ? yield(row) : row
        digest << "," unless index.zero?
        digest << JSON.generate(normalize_digest_value(payload))
      end
      digest << "]"
      digest.hexdigest
    end

    def normalize_digest_value(value)
      case value
      when Hash
        value.to_h.stringify_keys.sort.to_h.transform_values { |nested| normalize_digest_value(nested) }
      when Array
        value.map { |nested| normalize_digest_value(nested) }
      when BigDecimal
        (value.zero? ? 0.to_d : value).to_s("F")
      when Date, Time, ActiveSupport::TimeWithZone
        value.iso8601
      else
        value
      end
    end

    def parsed_year_totals(paychecks)
      paychecks.group_by { |paycheck| paycheck.fetch(:pay_date).year }.sort.to_h do |year, rows|
        [ year.to_s, year_payload(rows) ]
      end
    end

    def year_payload(rows)
      {
        "paycheck_count" => rows.size,
        "detailed_paycheck_count" => rows.count { |row| row_period_type(row) == "regular" },
        "opening_summary_count" => rows.count { |row| row_period_type(row) == "opening_summary" },
        "totals" => ImportService::MONEY_FIELDS.to_h do |field|
          total = rows.sum(0.to_d) { |row| row_value(row, field).to_d }.round(2)
          [ field.to_s, total.to_s("F") ]
        end
      }
    end

    def row_period_type(row)
      row.respond_to?(:historical_pay_period) ? row.historical_pay_period.period_type : row.fetch(:period_type)
    end

    def row_value(row, field)
      row.respond_to?(field) ? row.public_send(field) : row.fetch(field)
    end

    def canonical(value)
      JSON.parse(JSON.generate(value))
    end

    def record_audit!(review)
      AuditLog.record!(
        user: actor,
        organization_id: batch.company.organization_id,
        company_id: batch.company_id,
        action: "historical_imports#verify_cutover",
        record_type: "historical_import_cutover_reviews",
        record_id: review.id,
        subject_name: batch.source_label,
        metadata: {
          historical_import_batch_id: batch.id,
          passed: review.evidence_passed?,
          evidence_digest: review.evidence_digest,
          check_count: Array(review.evidence["checks"]).size
        }
      )
    end
  end
end
