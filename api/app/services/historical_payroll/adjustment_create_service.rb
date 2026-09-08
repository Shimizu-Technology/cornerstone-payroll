# frozen_string_literal: true

module HistoricalPayroll
  class AdjustmentCreateService
    ACKNOWLEDGEMENT = "RECORD HISTORICAL ADJUSTMENT"

    def initialize(paycheck:, actor:, attributes:, acknowledgement:, preview_digest:)
      @paycheck = paycheck
      @actor = actor
      @attributes = attributes
      @acknowledgement = acknowledgement
      @preview_digest = preview_digest
    end

    def call
      QuickbooksHistory::ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: paycheck.company_id)
      raise ArgumentError, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT

      idempotency_key = attributes.to_h.with_indifferent_access[:idempotency_key].to_s
      existing = HistoricalPaycheckAdjustment.find_by(company_id: paycheck.company_id, idempotency_key: idempotency_key)
      return existing if existing

      HistoricalPaycheckAdjustment.transaction do
        paycheck.company.lock!
        paycheck.historical_import_batch.lock!
        paycheck.lock!
        preview = AdjustmentPreviewService.new(paycheck: paycheck, actor: actor, attributes: attributes).call
        raise ArgumentError, preview.errors.join("; ") unless preview.ready?
        unless ActiveSupport::SecurityUtils.secure_compare(preview.digest, preview_digest.to_s)
          raise ArgumentError, "The historical adjustment preview changed. Build and review it again."
        end

        adjustment = paycheck.historical_paycheck_adjustments.create!(
          preview.attributes.merge(company: paycheck.company, created_by: actor)
        )
        record_audit!(adjustment, preview)
        adjustment
      end
    rescue ActiveRecord::RecordNotUnique
      HistoricalPaycheckAdjustment.find_by!(company_id: paycheck.company_id, idempotency_key: idempotency_key)
    end

    private

    attr_reader :paycheck, :actor, :attributes, :acknowledgement, :preview_digest

    def record_audit!(adjustment, preview)
      AuditLog.record!(
        user: actor,
        organization_id: paycheck.company.organization_id,
        company_id: paycheck.company_id,
        action: "historical_paycheck_adjustments#create",
        record_type: "historical_paycheck_adjustments",
        record_id: adjustment.id,
        subject_name: paycheck.source_employee_name,
        metadata: {
          historical_paycheck_id: paycheck.id,
          kind: adjustment.kind,
          filing_year: adjustment.filing_year,
          filing_quarter: adjustment.filing_quarter,
          preview_digest: preview.digest,
          downstream_pay_period_ids: preview.downstream_pay_period_ids,
          gross_pay_delta: adjustment.gross_pay.to_s,
          net_pay_delta: adjustment.net_pay.to_s
        }
      )
    end
  end
end
