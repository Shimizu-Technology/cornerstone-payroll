# frozen_string_literal: true

module PriorProviderHistory
  class Reversal
    ACKNOWLEDGEMENT = "REVERSE PRIOR PROVIDER HISTORY"

    def initialize(onboarding:, actor:, reason:, acknowledgement:)
      @onboarding, @actor, @reason, @acknowledgement = onboarding, actor, reason.to_s.strip, acknowledgement
    end

    def call
      Authorization.ensure_authorized!(actor: actor, company_id: onboarding.company_id)
      raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT
      raise ArgumentError, "Record a reversal reason (1–2000 characters)" unless reason.length.in?(1..2_000)
      onboarding.class.transaction do
        company.lock!
        onboarding.lock!
        batch.lock!
        @actor = Authorization.ensure_authorized!(actor: actor, company_id: company.id, lock: true)
        next onboarding if onboarding.status == "reversed"
        if company.pay_periods.committed.exists?
          raise ArgumentError, "History cannot be reversed after the first live payroll commitment; use a reviewed historical amendment"
        end
        if company.pay_periods.where.not(status: "retired_history").exists?
          raise ArgumentError, "Remove downstream uncommitted payroll before reversal so no stale calculation or approval remains"
        end
        if HistoricalPayroll::Ledger.new(batch: batch).adjustments.exists?
          raise ArgumentError, "History with reviewed adjustments cannot be reversed by onboarding"
        end
        if onboarding.status == "active"
          current = company.payroll_filing_responsibilities.for_year(onboarding.tax_year).map(&:attributes)
          unless QuickbooksHistory::CanonicalJson.normalize(JSON.parse(current.to_json).sort_by { |row| row.fetch("id") }) == QuickbooksHistory::CanonicalJson.normalize(onboarding.filing_after.sort_by { |row| row.fetch("id") })
            raise ArgumentError, "Filing ownership changed after activation; reconcile it before reversal"
          end
          if PayrollFilingEvent.joins(:payroll_filing_record).where(payroll_filing_records: { company_id: company.id, tax_year: onboarding.tax_year }).where("payroll_filing_events.created_at >= ?", onboarding.activated_at).exists?
            raise ArgumentError, "Filing evidence exists after activation; arrange a reviewed amendment"
          end
          ids = onboarding.filing_before.map { |row| row.fetch("id") }
          company.payroll_filing_responsibilities.for_year(onboarding.tax_year).where.not(id: ids).delete_all
          onboarding.filing_before.each do |attributes|
            company.payroll_filing_responsibilities.find(attributes.fetch("id")).update_columns(attributes.except("id", "company_id"))
          end
        end
        # Explicit audited reversal is the sole exception to snapshot lifecycle
        # immutability. Amounts, identities, source files and balances stay intact.
        batch.historical_ytd_bridges.where(status: "applied").update_all(status: "reversed", updated_at: Time.current)
        batch.update_columns(status: "reversed", updated_at: Time.current)
        company.pay_periods.where(retired_to_historical_import_batch_id: batch.id).order(:id).lock.load
        company.pay_periods.where(retired_to_historical_import_batch_id: batch.id).update_all(status: "calculated", retired_to_historical_import_batch_id: nil, updated_at: Time.current)
        onboarding.update!(status: "reversed", reversed_at: Time.current, reversed_by: actor, reversal_reason: reason)
        AuditLog.record!(user: actor, company_id: company.id, organization_id: company.organization_id,
          action: "prior_provider_history#reverse", record_type: "prior_provider_history_onboardings", record_id: onboarding.id,
          subject_name: batch.source_label, metadata: { batch_id: batch.id, reason: reason, source_run_ids: onboarding.evidence.fetch("source_run_ids") })
        onboarding
      end
    end

    private

    attr_reader :onboarding, :actor, :reason, :acknowledgement
    def company = onboarding.company
    def batch = onboarding.historical_import_batch
  end
end
