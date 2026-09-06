# frozen_string_literal: true

module QuickbooksHistory
  class ImportService
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

    def initialize(company:, files:, actor: nil)
      @company = company
      @files = files
      @actor = actor
    end

    def call
      parsed = BundleParser.new(files: files).call
      existing = HistoricalImportBatch.find_by(
        company: company,
        source_system: "quickbooks_online",
        bundle_digest: parsed.bundle_digest
      )
      return Result.new(batch: existing, idempotent: true) if existing

      batch = nil
      HistoricalImportBatch.transaction do
        duplicate_count = duplicate_source_count(parsed.paychecks)
        errors = Array(parsed.errors).dup
        errors << "#{duplicate_count} paycheck snapshot(s) already exist in applied QuickBooks history" if duplicate_count.positive?

        batch = HistoricalImportBatch.create!(
          company: company,
          created_by: actor,
          source_system: "quickbooks_online",
          source_label: parsed.source_label,
          bundle_digest: parsed.bundle_digest,
          importer_version: BundleParser::IMPORTER_VERSION,
          status: "previewed",
          source_file_manifest: parsed.manifest,
          preview_summary: parsed.summary,
          reconciliation_summary: parsed.reconciliation,
          warnings: parsed.warnings,
          validation_errors: errors
        )

        workers_by_name = create_workers!(batch, parsed.workers)
        periods_by_key = create_periods!(batch, parsed.periods)
        create_paychecks!(batch, parsed.paychecks, workers_by_name, periods_by_key)
      end

      Result.new(batch: batch, idempotent: false)
    rescue ActiveRecord::RecordNotUnique
      existing = HistoricalImportBatch.find_by!(
        company: company,
        source_system: "quickbooks_online",
        bundle_digest: parsed.bundle_digest
      )
      Result.new(batch: existing, idempotent: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(idempotent: false, error: e)
    end

    private

    attr_reader :company, :files, :actor

    def duplicate_source_count(paychecks)
      keys = paychecks.map { |row| row.fetch(:external_key) }
      HistoricalPaycheck.joins(:historical_import_batch)
                        .where(company: company, external_key: keys)
                        .merge(HistoricalImportBatch.visible_history)
                        .distinct
                        .count
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
        period = periods_by_key.fetch(period_key(row))
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

    def period_key(row)
      Digest::SHA256.hexdigest([ row.fetch(:period_start), row.fetch(:period_end), row.fetch(:pay_date), row.fetch(:period_type) ].join("|"))
    end
  end
end
