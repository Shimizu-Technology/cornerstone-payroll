# frozen_string_literal: true

require "tempfile"

module PriorProviderHistory
  class Conversion
    ACKNOWLEDGEMENT = "RECORD ALREADY PAID HISTORY"
    MAX_FILE_BYTES = 10.megabytes
    REVERSED_REPLAY_ERROR = "This history was recorded and then undone. Preview it again to record it as a new request"

    def initialize(company:, actor:, payload:, preview_digest:, idempotency_key:, files:, acknowledgement:)
      @company, @actor, @payload = company, actor, payload.deep_stringify_keys
      @preview_digest, @idempotency_key, @files, @acknowledgement = preview_digest, idempotency_key, Array(files), acknowledgement
    end

    def call
      Authorization.ensure_authorized!(actor: actor, company_id: company.id)
      raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT
      raise ArgumentError, "A unique request key is required" unless idempotency_key.to_s.match?(/\A[a-zA-Z0-9_-]{8,100}\z/)
      stored = []
      storage = QuickbooksHistory::SourceFileStorageService.new(company: company, actor: actor)
      PriorProviderHistoryOnboarding.transaction do
        company.lock!
        @actor = Authorization.ensure_authorized!(actor: actor, company_id: company.id, lock: true)
        existing = PriorProviderHistoryOnboarding.find_by(company: company, idempotency_key: idempotency_key)
        if existing
          raise ArgumentError, "This request key belongs to different history" unless existing.preview_digest == preview_digest && existing.evidence.fetch("payload") == payload
          # Replaying a recording that was later undone must not report success.
          raise ArgumentError, REVERSED_REPLAY_ERROR if existing.status == "reversed"

          next existing
        end
        ids = Array(payload["periods"]).filter_map { |row| row["run_id"] }
        company.pay_periods.where(id: ids).order(:id).lock.load
        plan = Plan.new(company: company, payload: payload).call
        raise ArgumentError, plan.errors.join("; ") unless plan.ready?
        raise ArgumentError, "History changed after reconciliation; preview it again" unless plan.digest == preview_digest
        stored = retain_sources!(storage, plan)
        batch = HistoricalImportBatch.create!(
          company: company, created_by: actor, applied_by: actor, applied_at: Time.current,
          status: "applied", source_system: "prior_provider", source_label: payload.fetch("provider_name").strip,
          # Unique per recording so unchanged history can be recorded again
          # after an undo; preview_digest still binds the reviewed plan.
          bundle_digest: Digest::SHA256.hexdigest("#{plan.digest}:#{idempotency_key}"), importer_version: SourceAdapter::VERSION,
          source_file_manifest: stored.map { |source| { "filename" => source.fetch(:original_filename), "sha256" => source.fetch(:sha256), "byte_size" => source.fetch(:byte_size), "report_type" => source.fetch(:report_type) } },
          preview_summary: { "totals" => plan.totals, "paycheck_count" => plan.periods.sum { |period| period.fetch("paychecks").size } },
          reconciliation_summary: { "passed" => true, "period_count" => plan.periods.size },
          tax_wage_reconciliation: { "passed" => true, "source" => "operator_verified_registers" },
          apply_acknowledgement: acknowledgement
        )
        stored.each { |attributes| batch.historical_import_source_files.create!(attributes) }
        create_snapshots!(batch, plan)
        onboarding = PriorProviderHistoryOnboarding.create!(
          company: company, historical_import_batch: batch, created_by: actor, tax_year: plan.tax_year,
          takeover_on: plan.takeover_on, preview_digest: plan.digest, idempotency_key: idempotency_key,
          evidence: { "payload" => payload, "source_run_ids" => plan.run_ids, "retirement" => "calculated_to_retired_history", "acknowledgement" => acknowledgement }
        )
        # Recorded history is only reachable through the historical payroll views.
        enabled_history = !company.historical_payroll_enabled?
        company.update!(historical_payroll_enabled: true) if enabled_history
        PriorProviderHistoryDraft.where(company: company).delete_all
        # This is archival retirement only: never enter the commitment/void path.
        company.pay_periods.where(id: plan.run_ids).update_all(status: "retired_history", retired_to_historical_import_batch_id: batch.id, updated_at: Time.current)
        AuditLog.record!(user: actor, company_id: company.id, organization_id: company.organization_id,
          action: "prior_provider_history#convert", record_type: "prior_provider_history_onboardings", record_id: onboarding.id,
          subject_name: batch.source_label, metadata: { batch_id: batch.id, preview_digest: plan.digest, source_run_ids: plan.run_ids, period_count: plan.periods.size, enabled_historical_payroll: enabled_history })
        onboarding
      end
    rescue StandardError
      storage&.cleanup(stored) if stored.present?
      raise
    end

    private

    attr_reader :company, :actor, :payload, :preview_digest, :idempotency_key, :files, :acknowledgement

    def retain_sources!(storage, plan)
      raise ArgumentError, "Attach the previous provider's paid registers before conversion" unless files.size.in?(1..10)
      files.each do |file|
        unless file.respond_to?(:tempfile) && File.size(file.tempfile.path).in?(1..MAX_FILE_BYTES)
          raise ArgumentError, "Each register must be a nonempty file no larger than 10 MB"
        end
        unless File.extname(file.original_filename.to_s).downcase.in?(%w[.pdf .csv .xlsx .xls .txt .json .png .jpg .jpeg])
          raise ArgumentError, "Use PDF, CSV, Excel, text, JSON or image register evidence"
        end
      end
      snapshot = Tempfile.new([ "prior-provider-reconciliation", ".json" ])
      snapshot.write(JSON.pretty_generate(payload.merge("preview_digest" => plan.digest)))
      snapshot.close
      sources = files.map { |file| [ file.tempfile.path, File.basename(file.original_filename), "prior_provider_register" ] } +
        [ [ snapshot.path, "reviewed-reconciliation.json", "prior_provider_reconciliation" ] ]
      manifest = sources.each_with_index.map do |(path, filename, type), index|
        { "filename" => filename.gsub(/[\u0000-\u001f]/, "").truncate(240), "byte_size" => File.size(path), "sha256" => Digest::SHA256.file(path).hexdigest, "report_type" => type, "position" => index }
      end
      source_files = sources.map { |path, filename, _type| QuickbooksHistory::BundleParser::SourceFile.new(path: path, original_filename: filename) }
      parsed = Struct.new(:manifest, :source_files).new(manifest, source_files)
      storage.store!(parsed: parsed)
    ensure
      snapshot&.unlink
    end

    def create_snapshots!(batch, plan)
      workers = {}
      plan.periods.each do |period|
        totals = Amounts.totals(period.fetch("paychecks"))
        snapshot = batch.historical_pay_periods.create!(company: company, external_key: period.fetch("key"), source_label: batch.source_label,
          start_date: period.fetch("start_date"), end_date: period.fetch("end_date"), pay_date: period.fetch("pay_date"),
          period_type: "regular", paycheck_count: period.fetch("paychecks").size, totals: totals)
        period.fetch("paychecks").each_with_index do |row, index|
          employee = company.employees.find(row.fetch("employee_id"))
          worker = workers[employee.id] ||= batch.historical_workers.create!(company: company, employee: employee,
            external_key: "employee-#{employee.id}", source_name: row.fetch("source_employee_name"), normalized_name: row.fetch("source_employee_name").squish.downcase,
            source_status: employee.status == "active" ? "active" : "inactive", mapping_status: "manual_match",
            private_snapshot: JSON.generate({ "identity_reviewed_by_id" => actor.id, "identity_reviewed_at" => Time.current.iso8601 }))
          amounts = row.slice(*HistoricalPaycheckAdjustment::MONEY_FIELDS.map(&:to_s), *Amounts::BREAKDOWNS)
          taxes = row.values_at("federal_income_tax", "social_security_tax", "medicare_tax").sum(0.to_d, &:to_d)
          employer_taxes = row.values_at("employer_social_security_tax", "employer_medicare_tax").sum(0.to_d, &:to_d)
          batch.historical_paychecks.create!(amounts.merge(
            company: company, employee: employee, historical_worker: worker, historical_pay_period: snapshot,
            external_key: "#{period.fetch('key')}:employee-#{employee.id}", source_employee_name: row.fetch("source_employee_name"), source_row_number: index + 1,
            pay_date: period.fetch("pay_date"), period_start: period.fetch("start_date"), period_end: period.fetch("end_date"),
            adjusted_gross: row.fetch("fit_taxable_wages"), employee_taxes: taxes, employer_taxes: employer_taxes,
            total_payroll_cost: row.fetch("gross_pay").to_d + employer_taxes + row.fetch("employer_contributions").to_d,
            payment_method: "paid_by_prior_provider", reconciliation_status: "matched", source_status: "paid_before_cornerstone",
            employee_tax_breakdown: %w[federal_income_tax social_security_tax medicare_tax].map { |field| { "label" => field.humanize, "amount" => row.fetch(field) } },
            employer_tax_breakdown: [ { "label" => "Social Security Employer", "amount" => row.fetch("employer_social_security_tax") }, { "label" => "Medicare Employer", "amount" => row.fetch("employer_medicare_tax") } ],
            source_metadata: { "verified_amounts" => row.slice(*Amounts::FIELDS), "source_run_id" => period["run_id"], "register_reference" => period.fetch("source_reference"), "verified_by_id" => actor.id, "provider_payment_reference" => row["provider_payment_reference"].to_s.presence }
          ))
        end
      end
    end
  end
end
