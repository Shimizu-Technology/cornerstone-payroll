# frozen_string_literal: true

class SendUserInviteEmailJob < ApplicationJob
  self.rls_mode = :exempt_tables_only

  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(user_id, invited_by_user_id = nil, invitation_url = nil)
    user = User.find_by(id: user_id)
    return if user.blank? || user.email.blank?

    invited_by = invited_by_user_id.present? ? User.find_by(id: invited_by_user_id) : nil
    success = UserInviteEmailService.send_invite(user: user, invited_by: invited_by, invitation_url: invitation_url)
    return :captured if success == :captured
    # Rechecked at send time: a stale job for a refused address sends nothing.
    return :refused if success == :refused
    # Retrying can't configure email. The user's row says it was skipped, so
    # staff see it and can resend once delivery is set up.
    return :skipped if success == :skipped

    # The error names the login, never its address.
    raise "Failed to send invite email for user_id=#{user.id}" unless success
  end
end
