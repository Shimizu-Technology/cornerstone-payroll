# frozen_string_literal: true

class ExpirePracticePortalAccessJob < ApplicationJob
  queue_as :default

  def perform
    User.where.not(practice_company_id: nil).where("active = TRUE OR clerk_invitation_id IS NOT NULL").find_each do |user|
      TestWorkspace::PortalAccess.deactivate_if_closed!(user)
    end
  end
end
