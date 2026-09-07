# frozen_string_literal: true

module QuickbooksHistory
  class YtdBridgePreviewService
    def initialize(batch:, actor:)
      @batch = batch
      @actor = actor
    end

    def call
      ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: batch.company_id)
      existing = batch.historical_ytd_bridge
      return existing if existing&.applied?

      HistoricalYtdBridge.transaction do
        batch.company.lock!
        batch.lock!
        existing = batch.historical_ytd_bridge
        next existing if existing&.applied?

        raise ArgumentError, "Lock the approved QuickBooks history before preparing historical YTD" unless batch.locked?

        bootstrap = batch.historical_client_bootstrap
        raise ArgumentError, "Apply the clean-client employee setup before preparing historical YTD" unless bootstrap&.applied?

        plan = YtdBridgePlan.new(batch: batch).call
        bridge = existing || batch.build_historical_ytd_bridge(
          company: batch.company,
          historical_client_bootstrap: bootstrap,
          created_by: actor
        )
        bridge.assign_attributes(
          status: "previewed",
          plan_digest: plan.digest,
          preview_summary: plan.summary,
          reconciliation_summary: plan.reconciliation,
          warnings: plan.warnings,
          validation_errors: plan.errors
        )
        bridge.save!
        record_audit!(bridge, plan)
        bridge
      end
    end

    private

    attr_reader :batch, :actor

    def record_audit!(bridge, plan)
      AuditLog.record!(
        user: actor,
        organization_id: batch.company.organization_id,
        company_id: batch.company_id,
        action: "historical_imports#preview_ytd_bridge",
        record_type: "historical_ytd_bridges",
        record_id: bridge.id,
        subject_name: batch.source_label,
        metadata: {
          historical_import_batch_id: batch.id,
          plan_digest: plan.digest,
          ready: plan.ready?,
          employee_count: plan.summary.fetch("employee_count", 0),
          balance_count: plan.summary.fetch("balance_count", 0),
          error_count: plan.errors.size
        }
      )
    end
  end
end
