# frozen_string_literal: true

module MigrationRehearsal
  class CloneJob < ApplicationJob
    queue_as :default

    def perform(company_id, batch_id, actor_id)
      company = Company.find(company_id)
      return if company.migration_rehearsal_status == "ready"

      Cloner.new(
        company: company,
        source_batch: HistoricalImportBatch.find(batch_id),
        actor: User.find(actor_id)
      ).call
    end
  end
end
