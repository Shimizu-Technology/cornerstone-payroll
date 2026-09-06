# frozen_string_literal: true

module QuickbooksHistory
  class ClientBootstrapPreviewService
    def initialize(batch:, actor:)
      @batch = batch
      @actor = actor
    end

    def call
      ensure_authorized_actor!
      existing = batch.historical_client_bootstrap
      return existing if existing&.applied?

      plan = ClientBootstrapPlan.new(batch: batch).call
      HistoricalClientBootstrap.transaction do
        batch.lock!
        raise ArgumentError, "The QuickBooks history must still be a preview" unless batch.previewed?

        bootstrap = batch.historical_client_bootstrap || batch.build_historical_client_bootstrap(
          company: batch.company,
          created_by: actor
        )
        bootstrap.assign_attributes(
          plan_digest: plan.digest,
          preview_summary: plan.summary,
          warnings: plan.warnings,
          validation_errors: plan.errors,
          review_items: plan.review_items
        )
        bootstrap.save!
        record_audit!(bootstrap, plan)
        bootstrap
      end
    end

    private

    attr_reader :batch, :actor

    def ensure_authorized_actor!
      return if actor&.can_access_company?(batch.company_id) && StaffRolePolicy.allowed?(actor, :manage_client_configuration)

      raise ArgumentError, "An attributed manager or administrator with client access is required"
    end

    def record_audit!(bootstrap, plan)
      AuditLog.record!(
        user: actor,
        organization_id: batch.company.organization_id,
        company_id: batch.company_id,
        action: "historical_imports#preview_client_bootstrap",
        record_type: "historical_client_bootstraps",
        record_id: bootstrap.id,
        subject_name: batch.source_label,
        metadata: {
          historical_import_batch_id: batch.id,
          plan_digest: plan.digest,
          ready: plan.ready?,
          worker_count: plan.summary.fetch("worker_count"),
          active_employee_count: plan.summary.fetch("active_employee_count"),
          review_count: plan.review_items.sum { |item| item.fetch("worker_count") },
          error_count: plan.errors.size
        }
      )
    end
  end
end
