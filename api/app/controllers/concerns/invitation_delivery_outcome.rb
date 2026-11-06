# frozen_string_literal: true

module InvitationDeliveryOutcome
  extend ActiveSupport::Concern

  private

  def invitation_delivery_response(user, clerk_result)
    return invitation_status_response("not_requested") unless user
    unless clerk_result[:success]
      return invitation_status_response("failed", error: clerk_result[:error].presence || "Invitation could not be created")
    end
    if clerk_result[:url].blank?
      return invitation_status_response("failed", error: "Invitation URL was not returned")
    end

    status = send_invite_email(user, clerk_result[:url])
    invitation_status_response(status, error: status == "failed" ? "Invitation email could not be submitted or queued" : nil)
  rescue StandardError => e
    Rails.logger.error("[InvitationDelivery] Failed user_id=#{user.id}: #{e.class}; content redacted")
    invitation_status_response("failed", error: "Invitation email could not be submitted or queued")
  end

  def invitation_status_response(status, error: nil)
    { invitation_delivery_status: status, invitation_sent: status == "submitted", invitation_error: error }
  end

  def send_invite_email(user, invitation_url)
    if StagingOutboundPolicy.staging?
      # Resolve capture now so a rehearsal acknowledgement describes the actual
      # transport outcome, rather than predicting what a later job might do.
      result = UserInviteEmailService.send_invite(user: user, invited_by: current_user, invitation_url: invitation_url)
      return "captured" if result == :captured
      return result == true ? "submitted" : "failed"
    end

    SendUserInviteEmailJob.perform_later(user.id, current_user&.id, invitation_url) ? "queued" : "failed"
  end
end
