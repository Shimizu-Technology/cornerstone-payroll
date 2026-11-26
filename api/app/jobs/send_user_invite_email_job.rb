# frozen_string_literal: true

class SendUserInviteEmailJob < ApplicationJob
  self.rls_mode = :exempt_tables_only

  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  # clerk_invitation_id is the invitation this email links to. Jobs queued
  # before it was passed have none and only check the invite is still pending.
  def perform(user_id, invited_by_user_id = nil, invitation_url = nil, clerk_invitation_id = nil)
    user = User.find_by(id: user_id)
    return if user.blank? || user.email.blank?
    # Checked on every attempt: once the invite is accepted, revoked or
    # replaced by a resend, this link is dead and the newer invite owns the
    # status, so a stale retry neither sends nor records anything.
    return :stale unless current_invitation?(user, clerk_invitation_id)

    invited_by = invited_by_user_id.present? ? User.find_by(id: invited_by_user_id) : nil
    success = UserInviteEmailService.send_invite(user: user, invited_by: invited_by, invitation_url: invitation_url,
      clerk_invitation_id: clerk_invitation_id)
    return :captured if success == :captured
    # Rechecked at send time: a stale job for a refused address sends nothing.
    return :refused if success == :refused
    # Retrying can't configure email. The user's row says it was skipped, so
    # staff see it and can resend once delivery is set up.
    return :skipped if success == :skipped

    # The error names the login, never its address.
    raise "Failed to send invite email for user_id=#{user.id}" unless success
  end

  private

  def current_invitation?(user, clerk_invitation_id)
    return false unless user.invitation_pending?

    clerk_invitation_id.blank? || user.clerk_invitation_id == clerk_invitation_id
  end
end
