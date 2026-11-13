# frozen_string_literal: true

module TestWorkspace
  module PortalAccess
    def self.deactivate_closed!(company)
      User.where(practice_company_id: company.id).find_each { |user| deactivate_if_closed!(user) }
    end

    def self.deactivate_if_closed!(user)
      return if user.practice_portal_open?

      closed = user.with_lock do
        next false if user.practice_portal_open?
        next true unless user.active?

        # Closing access must succeed even if unrelated profile data is invalid.
        # update_columns skips the model callback, so dispatch revocation explicitly.
        user.update_columns(active: false, updated_at: Time.current)
        PayrollAccess::RevocationDispatcher.call(user)
        AuditLog.record!(user: nil, organization_id: user.organization_id, company_id: user.practice_company_id,
          action: "test_workspace#portal_access_deactivated", record_type: "users", record_id: user.id,
          metadata: { reason: "practice_copy_unavailable_or_access_revoked" }, event_category: "security")
        true
      end
      revoke_pending_invitation!(user) if closed
    end

    def self.revoke_pending_invitation!(user)
      return unless user.invitation_pending? && user.clerk_invitation_id.present?

      service = ClerkInvitationService.new
      return unless service.configured?

      invitation_id = user.clerk_invitation_id
      result = service.revoke_invitation(invitation_id)
      if result[:success] || invitation_already_closed?(result)
        clear_invitation!(user, invitation_id)
      else
        Rails.logger.error("[PracticePortalAccess] Invitation revocation failed for user=#{user.id}")
      end
    rescue StagingOutboundPolicy::Blocked
      # Staging refuses this Clerk target, so a retry every minute can never succeed.
      Rails.logger.warn("[PracticePortalAccess] Staging blocked invitation revocation for user=#{user.id}")
      clear_invitation!(user, invitation_id)
    rescue StandardError => error
      # Retain the invitation id so the next sweep can retry independently.
      Rails.logger.error("[PracticePortalAccess] Invitation revocation failed for user=#{user.id}: #{error.class}")
    end

    # Clerk answers 4xx for an invitation that is already revoked, accepted or
    # expired, or that no longer exists. Retrying those every minute never helps.
    # Auth, timeout and rate-limit responses are kept for the next sweep.
    def self.invitation_already_closed?(result)
      status = result[:status].to_i
      status.between?(400, 499) && ![ 401, 403, 408, 429 ].include?(status)
    end

    def self.clear_invitation!(user, invitation_id)
      return if invitation_id.blank?

      User.where(id: user.id, clerk_invitation_id: invitation_id).update_all(clerk_invitation_id: nil, updated_at: Time.current)
      user.reload
    end
  end
end
