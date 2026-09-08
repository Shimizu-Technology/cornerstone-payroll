# frozen_string_literal: true

module HistoricalPayroll
  class AdjustmentReversalService
    ACKNOWLEDGEMENT = "REVERSE HISTORICAL ADJUSTMENT"

    def initialize(adjustment:, actor:, reason:, idempotency_key:, acknowledgement:)
      @adjustment = adjustment
      @actor = actor
      @reason = reason.to_s.strip
      @idempotency_key = idempotency_key.to_s.strip
      @acknowledgement = acknowledgement
    end

    def call
      QuickbooksHistory::ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: adjustment.company_id)
      raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT
      raise ArgumentError, "A reason is required" if reason.blank?
      return adjustment.reversal if adjustment.reversal
      existing = existing_for_idempotency_key
      return existing if existing

      HistoricalPaycheckAdjustment.transaction do
        adjustment.company.lock!
        adjustment.lock!
        next adjustment.reversal if adjustment.reversal

        attributes = {
          company: adjustment.company,
          historical_paycheck: adjustment.historical_paycheck,
          reverses_adjustment: adjustment,
          created_by: actor,
          kind: "reversal",
          effective_pay_date: adjustment.effective_pay_date,
          filing_year: adjustment.filing_year,
          filing_quarter: adjustment.filing_quarter,
          reason: reason,
          idempotency_key: idempotency_key,
          external_reference: adjustment.external_reference,
          evidence_metadata: { "reverses_adjustment_id" => adjustment.id }
        }
        Ledger::FIELDS.each { |field| attributes[field] = -adjustment.public_send(field) }
        Ledger::BREAKDOWN_FIELDS.each do |field|
          attributes[field] = Array(adjustment.public_send(field)).map do |entry|
            value = entry.to_h.with_indifferent_access
            { "label" => value[:label], "amount" => (-BigDecimal(value[:amount].to_s)).to_s("F") }
          end
        end
        reversal = HistoricalPaycheckAdjustment.create!(attributes)
        AuditLog.record!(
          user: actor,
          organization_id: adjustment.company.organization_id,
          company_id: adjustment.company_id,
          action: "historical_paycheck_adjustments#reverse",
          record_type: "historical_paycheck_adjustments",
          record_id: reversal.id,
          subject_name: adjustment.historical_paycheck.source_employee_name,
          metadata: { reverses_adjustment_id: adjustment.id, gross_pay_delta: reversal.gross_pay.to_s, net_pay_delta: reversal.net_pay.to_s }
        )
        reversal
      end
    rescue ActiveRecord::RecordNotUnique
      existing = adjustment.reload.reversal || existing_for_idempotency_key
      return existing if existing

      raise ArgumentError, "That idempotency key is already used by another historical adjustment"
    end

    private

    attr_reader :adjustment, :actor, :reason, :idempotency_key, :acknowledgement

    def existing_for_idempotency_key
      existing = HistoricalPaycheckAdjustment.find_by(
        company_id: adjustment.company_id,
        idempotency_key: idempotency_key
      )
      return unless existing
      return existing if existing.reverses_adjustment_id == adjustment.id

      raise ArgumentError, "That idempotency key is already used by another historical adjustment"
    end
  end
end
