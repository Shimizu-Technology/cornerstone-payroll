# frozen_string_literal: true

module TestWorkspace
  class CloneJob < ApplicationJob
    queue_as :default

    def perform(company_id, actor_id)
      company = Company.find(company_id)
      return if company.migration_rehearsal_status == "ready"

      actor = User.find_by(id: actor_id)
      unless actor
        company.update_columns(
          migration_rehearsal_status: "failed",
          migration_rehearsal_error: Cloner::FAILURE_MESSAGE,
          updated_at: Time.current
        )
        return
      end

      Cloner.new(company: company, actor: actor).call
    end
  end
end
