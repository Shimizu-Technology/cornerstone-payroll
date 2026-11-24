# frozen_string_literal: true

module EmployeeLinks
  # Staff start an employee's sign-up over (the staff screen is M4-9): for a
  # sign-up that can't finish, such as one whose Clerk account was created
  # but never bound (Resend refuses to rotate that one).
  #
  # It needs a reason and is audited. Before anything changes here, and
  # outside any transaction, it makes sure Clerk can't finish the old sign-up:
  # the pending login's Clerk invitation is revoked (an accepted one stays
  # accepted), and any Clerk account made from this link's sign-up for that
  # login (public metadata naming both) has its sessions ended and is
  # deleted, unless a Payroll login is bound to it. Then, like a resend, the
  # link gets a fresh token or code and a new invite generation, and the
  # pending login's binding fields are cleared, so a superseded ticket can
  # never bind. The pending login stays on the link for the next sign-up.
  #
  # Any Clerk step that can't be confirmed refuses the reset with nothing
  # changed here; it is safe to try again.
  class ResetSignUp < Resend
    REASON_MAX = 500
    CLERK_FAILED = "Couldn't remove the earlier sign-up from Clerk. Nothing was changed. Try again."

    def initialize(reason:, **options)
      super(**options)
      @reason = reason.is_a?(String) ? reason.strip : ""
    end

    def call
      raise Error, "Give a reason for resetting this sign-up" if @reason.empty?
      raise Error, "Keep the reason to #{REASON_MAX} characters or fewer" if @reason.length > REASON_MAX

      super
    end

    private

    def prepare_clerk!(pending)
      return { user_id: nil, invitation_id: nil, deleted_clerk_users: 0 } unless pending

      invitation_id = pending.clerk_invitation_id
      if invitation_id.present?
        state = PayrollInvitation.new(clerk: @clerk).close_invitation(invitation_id)
        raise Error, CLERK_FAILED if state == :unconfirmed
      end
      deleted = remove_clerk_accounts!(pending)
      { user_id: pending.id, invitation_id: invitation_id, deleted_clerk_users: deleted }
    end

    # The Clerk accounts made from this sign-up: at the pending login's
    # address, with public metadata naming this login and this link.
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
        next false if User.exists?(clerk_id: subject)

        sessions = @clerk.revoke_user_sessions(subject, email: pending.email)
        raise Error, CLERK_FAILED unless sessions[:success]
        raise Error, CLERK_FAILED unless @clerk.delete_user(subject, email: pending.email)[:success]

        true
      end
    end

    def retire_pending_sign_up!(user)
      user.update!(clerk_invitation_id: nil, invite_nonce_digest: nil, invite_nonce_expires_at: nil,
        invitation_status: "pending")
    end

    def audit_action
      "sign_up_reset"
    end

    def audit_metadata(closed)
      { reason: @reason, pending_login_id: closed[:user_id], deleted_clerk_users: closed[:deleted_clerk_users] }
    end
  end
end
