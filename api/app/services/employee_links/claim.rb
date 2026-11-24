# frozen_string_literal: true

module EmployeeLinks
  # Attaches an invite to a signed-in, existing Payroll login
  # (POST /api/v1/employee/links/claim): a client admin who is also an
  # employee, a staff member with a company 1 employee record, or an employee
  # at a second client. It never sends a Clerk invitation. The controller has
  # already required a fresh step-up (M4-1).
  #
  # Beyond the shared check, the login must be active, in the company's
  # organization, have no other open link at that company, and either be the
  # login the invite was routed to (confirmed as the same person, M4-3) or
  # carry the employee's first and last name. Every refusal is the same
  # generic failure.
  class Claim
    def self.call(...)
      new(...).call
    end

    def initialize(user:, token:, code:, date_of_birth:, ssn_last4:, azp: nil, request: nil,
      clerk: ClerkInvitationService.new)
      @user = user
      @check = { token: token, code: code, date_of_birth: date_of_birth, ssn_last4: ssn_last4 }
      @azp = azp
      @request = request
      @clerk = clerk
    end

    # Returns the active link, or nil.
    def call
      return unless @user&.payroll_access_allowed? && @user.clerk_id.present? && !@user.awaiting_clerk_binding?

      replaced_invitation = nil
      # The claimant (and an abandoned pending sign-up on the link) are locked
      # before the link, so two claims by one login serialize and the second
      # sees the first's link as open (EmployeeLinks lock order).
      link = Verify.call(**@check, request: @request, lock_users: ->(first_read) { lock_targets(first_read) }) do |candidate|
        next unless claimable?(candidate)

        replaced_invitation = retire_pending_user!(candidate)
        candidate.update!(user: @user, status: "active", activated_at: Time.current, invite_token_digest: nil,
          invite_code_digest: nil, failed_activation_attempts: 0, activation_locked_at: nil, activation_locked_until: nil)
        EmployeeLinks.audit!(candidate, "claimed", user: @user, request: @request,
          metadata: { via: candidate.invite_delivery, routed_to_login: candidate.claim_user_id.present? })
        candidate
      end
      revoke_invitation(replaced_invitation) if link && replaced_invitation
      link
    end

    private

    def lock_targets(link)
      [ @user, (link.user if link.user && link.user.id != @user.id && pending_sign_up?(link.user)) ].compact
    end

    def claimable?(link)
      return false if link.claim_user_id.present? && link.claim_user_id != @user.id
      return false unless link.company.organization_id == @user.organization_id
      return false unless EmployeeLinks.origin_allows_company?(@azp, link.company_id)
      return false if link.user_id.present? && link.user_id != @user.id && !pending_sign_up?(link.user)
      return false if EmployeeAccountLink.where(user_id: @user.id, company_id: link.company_id, status: %w[invited active])
        .where.not(id: link.id).exists?

      link.claim_user_id == @user.id || EmployeeContactValidator.login_name_matches?(@user, link.employee)
    end

    def pending_sign_up?(user)
      user.portal_employee? && user.awaiting_clerk_binding?
    end

    # Someone who started a new sign-up and then signed in with an existing
    # login instead: the unused pending login is closed.
    def retire_pending_user!(link)
      pending = link.user
      return unless pending && pending.id != @user.id

      # Already locked by Verify (lock_targets).
      invitation_id = pending.clerk_invitation_id
      pending.update!(active: false, invite_nonce_digest: nil, invite_nonce_expires_at: nil)
      invitation_id
    end

    def revoke_invitation(invitation_id)
      result = @clerk.revoke_invitation(invitation_id)
      return if result[:success]

      Rails.logger.warn("[EmployeeLinks::Claim] Could not revoke unused invitation #{invitation_id}")
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::Claim] Could not revoke unused invitation #{invitation_id}: #{error.class}")
    end
  end
end
