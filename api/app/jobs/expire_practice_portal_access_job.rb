# frozen_string_literal: true

class ExpirePracticePortalAccessJob < ApplicationJob
  queue_as :default

  def perform
    User.active.where.not(practice_company_id: nil).find_each do |user|
      TestWorkspace::PortalAccess.deactivate_if_closed!(user)
    end
  end
end
