# frozen_string_literal: true

module QuickbooksHistory
  class ImportService
    EXTERNAL_KEY_QUERY_BATCH_SIZE = 5_000
    MONEY_FIELDS = %i[
      gross_pay adjusted_gross pretax_deductions employee_taxes federal_income_tax
      social_security_tax medicare_tax after_tax_deductions net_pay employer_taxes
      employer_contributions total_payroll_cost
    ].freeze

    Result = Struct.new(:batch, :idempotent, :error, keyword_init: true) do
      def success?
        error.nil?
      end
    end

    def initialize(
      company:,
      files:,
      actor: nil,
      adapter: HistoricalPayrollImports::Registry.default.fetch!(HistoricalPayrollImports::Registry::DEFAULT_SOURCE_SYSTEM)
    )
      @company = company
      @files = files
      @actor = actor
      @adapter = adapter
    end

    def call
      parsed = adapter.parse(files: files)
      existing = find_existing_batch(parsed)
      return Result.new(batch: existing, idempotent: true) if existing&.source_files_complete_and_verified?

      storage_service = SourceFileStorageService.new(company: company, actor: actor)
      stored_source_files = storage_service.store!(parsed: parsed)
      source_files_persisted = false

      if existing
        attached_source_files = false
        HistoricalImportBatch.transaction do
          existing.lock!
          unless existing.source_files_complete_and_verified?
            attach_source_files!(existing, stored_source_files)
            attached_source_files = true
          end
        end
        source_files_persisted = attached_source_files
        return Result.new(batch: existing.reload, idempotent: true)
      end

      batch = nil
      HistoricalImportBatch.transaction do
        duplicate_count = duplicate_source_count(parsed.paychecks)
        errors = Array(parsed.errors).dup
        errors << "#{duplicate_count} paycheck snapshot(s) already exist in applied #{adapter.label} history" if duplicate_count.positive?

        batch = HistoricalImportBatch.create!(
          company: company,
          created_by: actor,
          source_system: adapter.key,
          source_label: parsed.source_label,
          bundle_digest: parsed.bundle_digest,
          importer_version: adapter.importer_version,
          status: "previewed",
          source_file_manifest: parsed.manifest,
          preview_summary: parsed.summary,
          reconciliation_summary: parsed.reconciliation,
          tax_wage_reconciliation: parsed.tax_wage_reconciliation,
          warnings: parsed.warnings,
          validation_errors: errors
        )
        attach_source_files!(batch, stored_source_files)
        # A blocked preview still retains every original file and the exact
        # reconciliation errors. Do not normalize conflicting report periods
        # into a ledger whose uniqueness constraints would hide that preview.
        create_tax_wage_reports!(batch, parsed.tax_wage_reports) if errors.empty?

        workers_by_name = create_workers!(batch, parsed.workers)
        periods_by_key = create_periods!(batch, parsed.periods)
        create_paychecks!(batch, parsed.paychecks, workers_by_name, periods_by_key)
      end
      source_files_persisted = true

      Result.new(batch: batch, idempotent: false)
    rescue ActiveRecord::RecordNotUnique => e
      existing = find_existing_batch(parsed)
      if existing.nil?
        # The legacy bundle-only index may still exist until migration
        # 20260907121000 runs. Never report an older importer as this upload.
        other_version = find_existing_bundle(parsed)
        if other_version
          return Result.new(
            idempotent: false,
            error: ArgumentError.new(
              "This #{adapter.label} bundle was already imported as #{other_version.importer_version}. " \
              "Complete the importer-version migration before re-importing it."
            )
          )
        end
      end
      raise e unless existing&.source_files_complete_and_verified?

      Result.new(batch: existing, idempotent: true)
    rescue ArgumentError, ActiveRecord::RecordInvalid, R2StorageService::ConfigurationError,
           SourceFileStorageService::StorageError => e
      Result.new(idempotent: false, error: e)
    ensure
      storage_service&.cleanup(stored_source_files) if stored_source_files.present? && !source_files_persisted
    end

    private

    attr_reader :company, :files, :actor, :adapter

    def find_existing_batch(parsed)
      HistoricalImportBatch.find_by(
        company: company,
        source_system: adapter.key,
        bundle_digest: parsed.bundle_digest,
        importer_version: adapter.importer_version
      )
    end

    def find_existing_bundle(parsed)
      HistoricalImportBatch.find_by(
        company: company,
        source_system: adapter.key,
        bundle_digest: parsed.bundle_digest
      )
    end

    def attach_source_files!(batch, stored_source_files)
      if batch.historical_import_source_files.exists?
        raise ArgumentError, "This #{adapter.label} preview has incomplete source-file evidence and cannot be repaired automatically"
      end

      stored_source_files.each { |attributes| batch.historical_import_source_files.create!(attributes) }
    end

    def duplicate_source_count(paychecks)
      paychecks.map { |row| row.fetch(:external_key) }
               .each_slice(EXTERNAL_KEY_QUERY_BATCH_SIZE)
               .sum do |keys|
        HistoricalPaycheck.joins(:historical_import_batch)
                           .where(company: company, external_key: keys)
                           .merge(HistoricalImportBatch.visible_history)
                           .distinct
                           .count
      end
    end

    def create_workers!(batch, worker_rows)
      employees_by_identity = company.employees.to_a.group_by do |employee|
        [ NameNormalizer.employee(employee), employee.ssn_digits ]
      end

      worker_rows.index_by { |row| row.fetch(:normalized_name) }.transform_values do |row|
        source_ssn = source_ssn_digits(row)
        candidates = source_ssn.present? ? employees_by_identity.fetch([ row.fetch(:normalized_name), source_ssn ], []) : []
        employee = candidates.one? ? candidates.first : nil
        batch.historical_workers.create!(
          company: company,
          employee: employee,
          external_key: row.fetch(:external_key),
          source_name: row.fetch(:source_name),
          normalized_name: row.fetch(:normalized_name),
          source_status: row.fetch(:source_status),
          hire_date: row[:hire_date],
          match_method: employee ? "exact_normalized_name_and_ssn" : nil,
          mapping_status: employee ? "exact_match" : "needs_review",
          match_confidence: employee ? 1 : nil,
          private_snapshot: row[:private_snapshot].present? ? JSON.generate(row.fetch(:private_snapshot)) : nil
        )
      end
    end

    def create_tax_wage_reports!(batch, report_rows)
      source_files = batch.historical_import_source_files.index_by(&:position)
      report_rows.each do |row|
        source_file = source_files.fetch(row.fetch(:source_position)) do
          raise ArgumentError, "Tax and Wage Summary evidence is missing its stored source file"
        end
        batch.historical_tax_wage_reports.create!(
          historical_import_source_file: source_file,
          company: company,
          source_position: row.fetch(:source_position),
          scope: row.fetch(:scope),
          period_start: row.fetch(:period_start),
          period_end: row.fetch(:period_end),
          tax_lines: row.fetch(:tax_lines),
          report_digest: row.fetch(:report_digest)
        )
      end
    end

    def source_ssn_digits(row)
      tax_info = row.fetch(:private_snapshot, {}).fetch("Tax info", "").to_s
      tax_info.match(/\b\d{3}-?\d{2}-?\d{4}\b/)&.to_s&.gsub(/\D/, "")
    end

    def create_periods!(batch, period_rows)
      period_rows.index_by { |row| row.fetch(:external_key) }.transform_values do |row|
        batch.historical_pay_periods.create!(
          company: company,
          external_key: row.fetch(:external_key),
          period_type: row.fetch(:period_type),
          start_date: row.fetch(:start_date),
          end_date: row.fetch(:end_date),
          pay_date: row.fetch(:pay_date),
          source_label: row.fetch(:source_label),
          paycheck_count: row.fetch(:paycheck_count),
          totals: row.fetch(:totals)
        )
      end
    end

    def create_paychecks!(batch, paycheck_rows, workers_by_name, periods_by_key)
      timestamp = Time.current
      rows = paycheck_rows.map do |row|
        worker = workers_by_name.fetch(row.fetch(:normalized_name))
        period = periods_by_key.fetch(PeriodKey.call(row))
        {
          historical_import_batch_id: batch.id,
          historical_pay_period_id: period.id,
          historical_worker_id: worker.id,
          company_id: company.id,
          employee_id: worker.employee_id,
          external_key: row.fetch(:external_key),
          source_row_number: row.fetch(:source_row_number),
          source_employee_name: row.fetch(:source_employee_name),
          pay_date: row.fetch(:pay_date),
          period_start: row.fetch(:period_start),
          period_end: row.fetch(:period_end),
          payment_method: row[:payment_method],
          check_number: row[:check_number],
          source_status: row.fetch(:source_status),
          reconciliation_status: row.fetch(:reconciliation_status),
          hours_total: row.fetch(:hours_total),
          hours_breakdown: row.fetch(:hours_breakdown),
          earnings_breakdown: row.fetch(:earnings_breakdown),
          pretax_deduction_breakdown: row.fetch(:pretax_deduction_breakdown),
          after_tax_deduction_breakdown: row.fetch(:after_tax_deduction_breakdown),
          employee_tax_breakdown: row.fetch(:employee_tax_breakdown),
          employer_tax_breakdown: row.fetch(:employer_tax_breakdown),
          employer_contribution_breakdown: row.fetch(:employer_contribution_breakdown),
          source_metadata: row.fetch(:source_metadata),
          created_at: timestamp,
          updated_at: timestamp
        }.merge(MONEY_FIELDS.to_h { |field| [ field, row.fetch(field) ] })
      end

      rows.each_slice(500) { |slice| HistoricalPaycheck.insert_all!(slice) }
    end
  end
end
