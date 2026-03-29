# frozen_string_literal: true

class SendUserInviteEmailJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(user_id, invited_by_user_id = nil, invitation_url = nil)
    user = User.find_by(id: user_id)
    return if user.blank? || user.email.blank?

    invited_by = invited_by_user_id.present? ? User.find_by(id: invited_by_user_id) : nil
    success = UserInviteEmailService.send_invite(user: user, invited_by: invited_by, invitation_url: invitation_url)
    raise "Failed to send invite email to #{user.email}" unless success
  end
end
