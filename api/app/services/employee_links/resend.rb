# frozen_string_literal: true

module EmployeeLinks
  # Keeps the link and rotates its token or code, so an earlier email or
  # printed code stops working, with a fresh 14-day expiry. A lock stays in
  # place until staff unlock it.
  #
  # The rotation is a new invite generation: a Clerk sign-up already started
  # for the old one can't bind, and its pending login's nonce is cleared. So
  # before rotating, and outside any transaction, Clerk must confirm that
  # sign-up's invitation is closed (revoking it if it is still pending). If
  # the person already accepted it (a Clerk account exists but isn't bound
  # yet), nothing rotates: they finish by signing in, which binds it
  # (SignUpAccepted). Staff can start over with ResetSignUp.
  class Resend
    ACCEPTED = "This person already created their account. Ask them to sign in to finish."
    ACCEPTED_STALE = "This person already created their account, but that sign-up can no longer finish. " \
      "Reset their sign-up to send a new invite."
    UNCONFIRMED = "Couldn't confirm with Clerk that the earlier sign-up is closed. Nothing was changed. Try again."
    CHANGED = "This invite changed while it was being resent. Try again."
    RESET_PENDING = "A reset of this sign-up hasn't finished. Reset the sign-up again to finish it."

    def self.call(...)
      new(...).call
    end

    def initialize(link:, actor:, delivery: nil, confirm_same_person_email: false, request: nil,
      clerk: ClerkInvitationService.new)
      @link = link
      @actor = actor
      @delivery = (delivery.presence || link.invite_delivery || "email").to_s
      @confirm_same_person_email = confirm_same_person_email
      @request = request
      @clerk = clerk
    end

    def call
      raise Error, "Choose email or a printed sign-up code" unless %w[email code].include?(@delivery)

      EmployeeLinks.require_invitation_management!(@actor, @link.company)
      raise Error, "The employee app isn't turned on for this company" unless @link.portal_enabled?
      raise Error, RESET_PENDING if EmployeeAccountLink.where(id: @link.id).pick(:sign_up_reset_requested_at)

      employee = @link.employee
      # Clerk first, outside the transaction; the locked block re-checks that
      # the login and its invitation are still the ones Clerk closed.
      closed = prepare_clerk!(current_pending_login)
      result = ApplicationRecord.transaction do
        EmployeeLinks.lock_for_issuance!(@link.company)
        # EmployeeLinks lock order: employee, then the link's login, then the link.
        employee.lock!
        pending_id = EmployeeAccountLink.where(id: @link.id).pick(:user_id)
        EmployeeLinks.lock_users!([ pending_id ])
        @link.lock!
        raise Error, CHANGED unless @link.user_id == pending_id
        raise Error, "Only an open invite can be resent" unless @link.invited?
        raise Error, RESET_PENDING if @link.sign_up_reset_pending?
        raise Error, "Only active employees can be invited" unless employee.active?
        raise Error, "The employee app isn't turned on for this company" unless @link.portal_enabled?

        pending = @link.user if pending_sign_up?(@link.user)
        raise Error, CHANGED unless closed.fetch(:user_id) == pending&.id &&
          closed.fetch(:invitation_id) == pending&.clerk_invitation_id

        @link.claim_user = route_login(employee)
        @link.invited_by = @actor
        credentials = Credentials.issue(@link, delivery: @delivery, email: employee.email)
        @link.save!
        retire_pending_sign_up!(pending) if pending
        path = EmployeeLinks.invite_path(@link.claim_user)
        EmployeeLinks.audit!(@link, audit_action, user: @actor, request: @request,
          metadata: audit_metadata(closed).merge(delivery: @delivery, path: path, expires_at: @link.invite_expires_at.iso8601))
        Invite::Result.new(link: @link, token: credentials.token, code: credentials.code, path: path, email_status: nil)
      end
      return result unless @delivery == "email"

      result.with(email_status: InviteEmail.deliver(link: result.link, token: result.token, path: result.path))
    end

    private

    def current_pending_login
      user = User.find_by(id: EmployeeAccountLink.where(id: @link.id).pick(:user_id))
      user if pending_sign_up?(user)
    end

    def pending_sign_up?(user)
      user&.portal_employee? && user.awaiting_clerk_binding?
    end

    # Confirms the pending login's Clerk invitation can't be accepted any
    # more. Returns what was confirmed, for the locked re-check.
    def prepare_clerk!(pending)
      invitation_id = pending&.clerk_invitation_id
      if invitation_id.present?
        case PayrollInvitation.new(clerk: @clerk).close_invitation(invitation_id)
        when :accepted
          raise SignUpAccepted, bindable?(pending) ? ACCEPTED : ACCEPTED_STALE
        when :unconfirmed
          raise Error, UNCONFIRMED
        end
      end
      { user_id: pending&.id, invitation_id: invitation_id }
    end

    # An accepted, unbound sign-up still binds at the person's next sign-in
    # while its nonce and its link's invite are both open.
    def bindable?(pending)
      now = Time.current
      pending.active? && pending.invite_nonce_digest.present? && pending.invite_nonce_expires_at&.>(now) &&
        @link.reload.invite_open?(now) && !@link.activation_locked?(now)
    end

    # The pending login stays on the link (a later sign-up reuses it), but
    # nothing started for the old generation can bind it.
    def retire_pending_sign_up!(user)
      user.update!(invite_nonce_digest: nil, invite_nonce_expires_at: nil)
    end

    def audit_action
      "invite_resent"
    end

    def audit_metadata(_closed)
      {}
    end

    # Same routing as a new invite (Invite#route_login); a code resend keeps
    # the login the invite was already routed to.
    def route_login(employee)
      Invite.new(employee: employee, actor: @actor, delivery: @delivery,
        confirm_same_person_email: @confirm_same_person_email, request: @request)
        .route_login(current: (@link.claim_user if @delivery == "code"))
    end
  end
end
