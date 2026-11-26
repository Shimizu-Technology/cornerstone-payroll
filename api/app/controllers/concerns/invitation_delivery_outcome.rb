# frozen_string_literal: true

module InvitationDeliveryOutcome
  extend ActiveSupport::Concern

  INVITATION_EMAIL_ERRORS = {
    "failed" => "Invitation email could not be submitted or queued",
    "skipped" => "Email delivery isn't set up on this server, so no invitation email was sent"
  }.freeze
  # An invite email still counts while its invitation is open.
  LIVE_INVITE_EMAIL_STATUSES = %w[queued sent captured].freeze

  private

  def invitation_redirect_url
    frontend = ENV.fetch("FRONTEND_URL") { ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173").split(",").first.strip }
    "#{frontend}/login"
  end

  def invitation_delivery_response(user, clerk_result)
    return invitation_status_response("not_requested") unless user
    unless clerk_result[:success]
      record_invitation_failure(user, clerk_result)
      return invitation_status_response("failed", error: clerk_result[:error].presence || "Invitation could not be created")
    end
    if clerk_result[:url].blank?
      UserInviteEmailService.record_email_status(user, false)
      return invitation_status_response("failed", error: "Invitation URL was not returned")
    end

    status = send_invite_email(user, clerk_result[:url], clerk_result[:invitation_id].presence || user.clerk_invitation_id)
    invitation_status_response(status, error: INVITATION_EMAIL_ERRORS[status])
  rescue StandardError => e
    Rails.logger.error("[InvitationDelivery] Failed user_id=#{user.id}: #{e.class}; content redacted")
    UserInviteEmailService.record_email_status(user, false)
    invitation_status_response("failed", error: INVITATION_EMAIL_ERRORS["failed"])
  end

  # No new invitation went out. Leave the status alone when Clerk says the
  # old one was already accepted, or when the old one is still open and its
  # email went out; otherwise the login has no usable invite email.
  def record_invitation_failure(user, clerk_result)
    return if clerk_result[:previous_invitation] == :accepted
    return UserInviteEmailService.record_email_status(user, :refused) if clerk_result[:refused]
    if clerk_result[:previous_invitation] == :kept
      return if LIVE_INVITE_EMAIL_STATUSES.include?(User.where(id: user.id).pick(:invite_email_status))
    end

    UserInviteEmailService.record_email_status(user, false)
  end

  def invitation_status_response(status, error: nil)
    { invitation_delivery_status: status, invitation_sent: status == "submitted", invitation_error: error }
  end

  def send_invite_email(user, invitation_url, clerk_invitation_id)
    # Checked before enqueue; the job and the transport check again.
    demo_company = DemoOutbound.demo_company_for(user)
    if demo_company && !DemoOutbound.permit?(company: demo_company, email: user.email, channel: "user_invite_email", user: user)
      UserInviteEmailService.record_email_status(user, :refused)
      return "failed"
    end

    if StagingOutboundPolicy.staging?
      # Resolve capture now so a rehearsal acknowledgement describes the actual
      # transport outcome, rather than predicting what a later job might do.
      result = UserInviteEmailService.send_invite(user: user, invited_by: current_user, invitation_url: invitation_url,
        clerk_invitation_id: clerk_invitation_id)
      return "captured" if result == :captured
      return "skipped" if result == :skipped
      return result == true ? "submitted" : "failed"
    end

    # Queueing a job that can only skip would report "queued" for an email
    # that never goes out. Say so now instead.
    unless UserInviteEmailService.configured?
      Rails.logger.error("[InvitationDelivery] Skipped user_id=#{user.id}: email delivery is not configured")
      UserInviteEmailService.record_email_status(user, :skipped)
      return "skipped"
    end

    # Recorded before the enqueue: a fast job's "sent" must not be overwritten.
    UserInviteEmailService.record_email_status(user, "queued")
    return "queued" if SendUserInviteEmailJob.perform_later(user.id, current_user&.id, invitation_url, clerk_invitation_id)

    UserInviteEmailService.record_email_status(user, false)
    "failed"
  end
end
