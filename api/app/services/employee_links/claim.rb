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
  # generic failure, except these, named once the check passed
  # (EmployeeLinks.claim_email_refusal): refusal == :email_mismatch when the
  # Clerk account's verified primary email isn't the employee's email on file
  # with proof of the inbox, or :code_retired for a code staff didn't issue.
  class Claim
    attr_reader :refusal

    def self.call(...)
      new(...).call
    end

    def initialize(user:, token:, code:, date_of_birth:, ssn_last4:, azp: nil, request: nil, terms_version: nil, session: nil,
      clerk: ClerkInvitationService.new)
      @user = user
      # The verified Clerk token payload (Reactivate checks when it was issued).
      @session = session
      @check = { token: token, code: code, date_of_birth: date_of_birth, ssn_last4: ssn_last4 }
      @azp = azp
      @request = request
      @terms_version = terms_version
      @clerk = clerk
    end

    # Returns the active link, or nil.
    def call
      return unless user_allowed?

      @identity = clerk_identity
      replaced_invitation = nil
      # The claimant (and an abandoned pending sign-up on the link) are locked
      # before the link, so two claims by one login serialize and the second
      # sees the first's link as open (EmployeeLinks lock order).
      # A link on the other side of the demo boundary is refused before
      # anything on it is locked, counted or written. The login is re-read
      # each time, so the check under the lock sees its current home company.
      # The demo session (azp) and browser Origin rules are part of admission,
      # so a request that could never claim a demo link isn't counted as a
      # guess against it (claimable? re-checks them under the lock).
      origin = @request&.headers&.[]("Origin")
      admit = lambda do |link|
        EmployeeLinks.demo_boundary_allows?(@user.reload, link.company) &&
          EmployeeAppSwitch::Enforcement.demo_request_allowed?(link.company) &&
          EmployeeLinks.demo_request_allowed?(link.company, @azp) && EmployeeLinks.demo_origin_allowed?(link.company, origin)
      end
      link = Verify.call(**@check, request: @request, admit: admit, lock_users: ->(first_read) { lock_targets(first_read) }) do |candidate|
        # Re-read the login under its lock (taken before the link's).
        @user.reload
        next unless user_allowed? && claimable?(candidate)

        email_on_file = candidate.employee.email.to_s.strip.presence
        replaced_invitation = retire_pending_user!(candidate)
        attach!(candidate)
        ActivationNoticeEmail.schedule!(link: candidate, email_on_file: email_on_file)
        candidate
      end
      revoke_invitation(replaced_invitation) if link && replaced_invitation
      link
    end

    private

    def user_allowed?
      @user&.payroll_access_allowed? && @user.clerk_id.present? && !@user.awaiting_clerk_binding?
    end

    def attach!(link)
      link.update!(user: @user, status: "active", activated_at: Time.current, invite_token_digest: nil,
        invite_code_digest: nil, failed_activation_attempts: 0, activation_locked_at: nil, activation_locked_until: nil)
      EmployeeLinks.audit!(link, audit_action, user: @user, request: @request,
        metadata: { via: link.invite_delivery, invited_by_id: link.invited_by_id,
          routed_to_login: link.claim_user_id.present?, terms_version: @terms_version }.compact)
    end

    def audit_action
      "claimed"
    end

    def lock_targets(link)
      [ @user, (link.user if link.user && link.user.id != @user.id && pending_sign_up?(link.user)) ].compact
    end

    def claimable?(link)
      return false if link.claim_user_id.present? && link.claim_user_id != @user.id
      return false unless link.company.organization_id == @user.organization_id
      return false unless EmployeeLinks.demo_boundary_allows?(@user, link.company)
      return false unless EmployeeLinks.origin_allows_company?(@azp, link.company_id)
      return false unless EmployeeLinks.demo_request_allowed?(link.company, @azp)
      return false unless EmployeeLinks.demo_origin_allowed?(link.company, @request&.headers&.[]("Origin"))
      return false unless DemoOutbound.permit?(company: link.company, email: @user.email, channel: "employee_link_claim", user: @user)
      return false if link.user_id.present? && link.user_id != @user.id && !pending_sign_up?(link.user)
      return false if EmployeeAccountLink.where(user_id: @user.id, company_id: link.company_id, status: %w[invited active])
        .where.not(id: link.id).exists?
      return false unless same_person?(link)

      @refusal = EmployeeLinks.claim_email_refusal(link, @identity)
      @refusal.nil?
    end

    # The signed-in Clerk account's addresses, read before any lock (Clerk
    # calls stay outside transactions). nil when Clerk can't answer.
    def clerk_identity
      clerk_user = @clerk.fetch_user(@user.clerk_id)
      ClerkInvitationService.email_summary(clerk_user) if clerk_user
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::Claim] Could not read the Clerk account: #{error.class}")
      nil
    end

    def same_person?(link)
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
      pending.update!(EmployeeLinks.pending_closure_attributes(pending))
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
