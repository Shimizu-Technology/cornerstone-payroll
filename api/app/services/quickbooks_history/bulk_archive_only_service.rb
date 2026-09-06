# frozen_string_literal: true

module QuickbooksHistory
  class BulkArchiveOnlyService
    def initialize(batch:, actor:)
      @batch = batch
      @actor = actor
    end

    def call
      ensure_authorized_actor!

      HistoricalImportBatch.transaction do
        batch.lock!
        raise ArgumentError, "Unlinked workers can only be bulk-reviewed while the batch is a preview" unless batch.previewed?

        workers = batch.historical_workers.where(mapping_status: "needs_review")
        count = workers.count
        workers.update_all(
          employee_id: nil,
          mapping_status: "archive_only",
          match_method: "archive_only",
          match_confidence: nil,
          updated_at: Time.current
        )
        count
      end
    end

    private

    attr_reader :batch, :actor

    def ensure_authorized_actor!
      authorized = actor.present? &&
        actor.can_access_company?(batch.company_id) &&
        StaffRolePolicy.allowed?(actor, :manage_client_configuration)
      return if authorized

      raise ArgumentError, "An attributed manager or administrator with company access is required"
    end
  end
end
