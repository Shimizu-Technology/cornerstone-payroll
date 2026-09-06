# frozen_string_literal: true

module QuickbooksHistory
  class ClientBootstrapJob < ApplicationJob
    queue_as :default

    def perform(bootstrap_id, actor_id, apply_started_at)
      bootstrap = HistoricalClientBootstrap.find(bootstrap_id)
      return unless current_attempt?(bootstrap, apply_started_at)

      actor = User.find(actor_id)
      ClientBootstrapApplyService.new(
        bootstrap: bootstrap,
        actor: actor,
        acknowledgement: ClientBootstrapApplyService::ACKNOWLEDGEMENT,
        expected_apply_started_at: apply_started_at
      ).call
    rescue ClientBootstrapApplyService::StaleBootstrapAttempt
      nil
    rescue StandardError => e
      persist_failure(bootstrap_id, actor_id, apply_started_at, e)
    end

    private

    def persist_failure(bootstrap_id, actor_id, apply_started_at, error)
      Rails.logger.error(
        "Historical client bootstrap failed for bootstrap #{bootstrap_id}: " \
        "#{error.class} job_id=#{job_id}"
      )
      bootstrap = HistoricalClientBootstrap.find_by(id: bootstrap_id)
      return unless bootstrap

      bootstrap.with_lock do
        return unless current_attempt?(bootstrap, apply_started_at)

        bootstrap.update!(
          status: "failed",
          apply_error: "Employee preparation could not be completed. Review the current setup preview and try again."
        )
        actor = User.find_by(id: actor_id)
        AuditLog.record!(
          user: actor,
          organization_id: bootstrap.company.organization_id,
          company_id: bootstrap.company_id,
          action: "historical_imports#client_bootstrap_failed",
          record_type: "historical_client_bootstraps",
          record_id: bootstrap.id,
          subject_name: bootstrap.historical_import_batch.source_label,
          metadata: {
            historical_import_batch_id: bootstrap.historical_import_batch_id,
            status: bootstrap.status,
            error_class: error.class.name
          }
        )
      end
    rescue StandardError => persistence_error
      Rails.logger.error(
        "Historical client bootstrap failure could not be persisted for bootstrap #{bootstrap_id}: " \
        "#{persistence_error.class} job_id=#{job_id}"
      )
    end

    def current_attempt?(bootstrap, apply_started_at)
      bootstrap&.pending? && bootstrap.apply_started_at&.iso8601(6) == apply_started_at
    end
  end
end
