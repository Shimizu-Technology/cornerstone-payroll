# frozen_string_literal: true

module EmployeeLinks
  # Staff start an employee's sign-up over (the staff screen is M4-9): for a
  # sign-up that can't finish, such as one whose Clerk account was created
  # but never bound (Resend refuses to rotate that one). It needs a reason
  # and every phase is audited.
  #
  # It runs in three phases, so a sign-in that binds at the same moment
  # never loses its Clerk account:
  #
  #   1. Under the lock order bind uses (employee, login, link), it checks
  #      the pending login is still unbound, then moves the link to a new
  #      invite generation with no token or code, clears the login's nonce
  #      and records the pending reset (who, why, when). From this commit on
  #      the old sign-up can't bind: bind checks the generation and nonce,
  #      and refuses while the reset is pending (invite_open?).
  #   2. Outside any transaction, Clerk: the login's invitation is revoked
  #      (an accepted one stays accepted), and each Clerk account whose
  #      backend-written public metadata names this login and this link has
  #      its sessions ended and is deleted, unless a Payroll login is bound
  #      to it (checked again right before each deletion).
  #   3. Under the same locks, the pending reset is cleared and a new invite
  #      issued, as a resend would.
  #
  # If Clerk fails in phase 2, the reset stays pending (the invite stays
  # closed) and running the reset again resumes it from phase 2.
  class ResetSignUp < Resend
    REASON_MAX = 500
    CLERK_FAILED = "Couldn't remove the earlier sign-up from Clerk. The reset is still pending and the old sign-up " \
      "can't be used. Reset the sign-up again to finish."
    BOUND = "This person's login is already set up, so there is no sign-up to reset."
    CHANGED = "This invite changed while its sign-up was being reset. Reset the sign-up again to finish."

    def initialize(reason:, **options)
      super(**options)
      @reason = reason.is_a?(String) ? reason.strip : ""
    end

    def call
      raise Error, "Give a reason for resetting this sign-up" if @reason.empty?
      raise Error, "Keep the reason to #{REASON_MAX} characters or fewer" if @reason.length > REASON_MAX
      raise Error, "Choose email or a printed sign-up code" unless %w[email code].include?(@delivery)

      EmployeeLinks.require_staff!(@actor, @link.company)
      pending_id = close_old_sign_up!
      closed = remove_from_clerk!(pending_id)
      result = issue_new_invite!(closed)
      return result unless @delivery == "email"

      result.with(email_status: InviteEmail.deliver(link: result.link, token: result.token, path: result.path))
    end

    private

    # Phase 1. Returns the pending login's id (nil when the link has none).
    def close_old_sign_up!
      ApplicationRecord.transaction do
        pending = lock_link_and_login!
        if @link.sign_up_reset_pending?
          EmployeeLinks.audit!(@link, "sign_up_reset_resumed", user: @actor, request: @request,
            metadata: { reason: @reason, pending_login_id: pending&.id })
          next pending&.id
        end

        now = Time.current
        @link.update!(invite_generation: @link.invite_generation + 1, invite_token_digest: nil,
          invite_code_digest: nil, sign_up_reset_requested_at: now, sign_up_reset_requested_by: @actor,
          sign_up_reset_reason: @reason)
        pending&.update!(invite_nonce_digest: nil, invite_nonce_expires_at: nil)
        EmployeeLinks.audit!(@link, "sign_up_reset_started", user: @actor, request: @request,
          metadata: { reason: @reason, pending_login_id: pending&.id })
        pending&.id
      end
    end

    # Phase 2, outside any transaction.
    def remove_from_clerk!(pending_id)
      pending = User.find_by(id: pending_id) if pending_id
      return { user_id: nil, invitation_id: nil, deleted_clerk_users: 0 } unless pending

      invitation_id = pending.clerk_invitation_id
      if invitation_id.present?
        state = PayrollInvitation.new(clerk: @clerk).close_invitation(invitation_id)
        raise Error, CLERK_FAILED if state == :unconfirmed
      end
      { user_id: pending.id, invitation_id: invitation_id, deleted_clerk_users: remove_clerk_accounts!(pending) }
    end

    # The Clerk accounts made from this sign-up: at the pending login's
    # address, with public metadata (which only the backend writes) naming
    # this login and this link.
    def remove_clerk_accounts!(pending)
      accounts = @clerk.users_with_email(pending.email)
      raise Error, CLERK_FAILED if accounts.nil?

      made_here = accounts.select do |account|
        metadata = account["public_metadata"]
        metadata.is_a?(Hash) && metadata["payroll_user_id"] == pending.id && metadata["payroll_employee_link_id"] == @link.id
      end
      made_here.count do |account|
        subject = account.fetch("id")
        # Never remove a Clerk account a Payroll login is bound to.
        next false if bound_to_payroll?(subject)

        sessions = @clerk.revoke_user_sessions(subject, email: pending.email)
        raise Error, CLERK_FAILED unless sessions[:success]
        next false if bound_to_payroll?(subject)
        raise Error, CLERK_FAILED unless @clerk.delete_user(subject, email: pending.email)[:success]

        true
      end
    end

    def bound_to_payroll?(subject)
      User.exists?(clerk_id: subject)
    end

    # Phase 3.
    def issue_new_invite!(closed)
      ApplicationRecord.transaction do
        pending = lock_link_and_login!
        raise Error, CHANGED unless @link.sign_up_reset_pending? && pending&.id == closed.fetch(:user_id) &&
          pending&.clerk_invitation_id == closed.fetch(:invitation_id)

        @link.claim_user = route_login(@link.employee)
        @link.invited_by = @actor
        credentials = Credentials.issue(@link, delivery: @delivery, email: @link.employee.email, issued_by_staff: EmployeeLinks.staff_management_allowed?(@actor, @link.company))
        requested = { requested_at: @link.sign_up_reset_requested_at.iso8601, requested_by_id: @link.sign_up_reset_requested_by_id,
                      requested_reason: @link.sign_up_reset_reason }
        @link.assign_attributes(sign_up_reset_requested_at: nil, sign_up_reset_requested_by: nil, sign_up_reset_reason: nil)
        @link.save!
        pending&.update!(clerk_invitation_id: nil, invite_nonce_digest: nil, invite_nonce_expires_at: nil,
          invitation_status: "pending")
        path = EmployeeLinks.invite_path(@link.claim_user)
        EmployeeLinks.audit!(@link, "sign_up_reset", user: @actor, request: @request,
          metadata: requested.merge(reason: @reason, pending_login_id: closed[:user_id],
            deleted_clerk_users: closed[:deleted_clerk_users], delivery: @delivery, path: path,
            expires_at: @link.invite_expires_at.iso8601))
        Invite::Result.new(link: @link, token: credentials.token, code: credentials.code, path: path, email_status: nil)
      end
    end

    # The EmployeeLinks lock order: employee, then the link's login, then the
    # link, re-checking the link still points at that login. Returns the
    # locked pending login, or nil when the link has none.
    def lock_link_and_login!
      employee = @link.employee
      employee.lock!
      pending_id = EmployeeAccountLink.where(id: @link.id).pick(:user_id)
      pending = EmployeeLinks.lock_users!([ pending_id ]).first
      @link.lock!
      raise Error, CHANGED unless @link.user_id == pending_id
      raise Error, "Only an open invite can be reset" unless @link.invited?
      raise Error, BOUND if pending && !pending_sign_up?(pending)
      raise Error, "Only active employees can be invited" unless employee.active?
      raise Error, "The employee app isn't turned on for this company" unless @link.portal_enabled?

      pending
    end
  end
end
