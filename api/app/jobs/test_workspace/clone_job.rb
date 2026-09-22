# frozen_string_literal: true

module TestWorkspace
  class CloneJob < ApplicationJob
    queue_as :default

    def perform(company_id, actor_id)
      company = Company.find(company_id)
      return if company.migration_rehearsal_status == "ready"

      Cloner.new(company: company, actor: User.find(actor_id)).call
    end
  end
end
