# frozen_string_literal: true

module EmployeeLinks
  # Keeps the link and rotates its token or code, so an earlier email or
  # printed code stops working, with a fresh 14-day expiry. A lock stays in
  # place until staff unlock it.
  #
  # The rotation is a new invite generation: a Clerk sign-up already started
  # for the old one can't bind. Its pending login's nonce is cleared here, and
  # its Clerk invitation is revoked after commit (best effort; a later sign-up
  # confirms it closed before making a new one).
  class Resend
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

      EmployeeLinks.require_staff!(@actor, @link.company)
      employee = @link.employee
      superseded_invitation = nil
      result = ApplicationRecord.transaction do
        # EmployeeLinks lock order: employee, then the link's login, then the link.
        employee.lock!
        pending_id = EmployeeAccountLink.where(id: @link.id).pick(:user_id)
        EmployeeLinks.lock_users!([ pending_id ])
        @link.lock!
        raise Error, "This invite changed while it was being resent. Try again." unless @link.user_id == pending_id
        raise Error, "Only an open invite can be resent" unless @link.invited?
        raise Error, "Only active employees can be invited" unless employee.active?
        raise Error, "The employee app isn't turned on for this company" unless @link.portal_enabled?

        if @delivery == "email"
          @link.claim_user = check_email!(employee)
        end
        credentials = Credentials.issue(@link, delivery: @delivery, email: employee.email)
        @link.save!
        superseded_invitation = retire_pending_sign_up!(@link.user)
        path = @link.claim_user_id ? "claim" : "sign_up"
        EmployeeLinks.audit!(@link, "invite_resent", user: @actor, request: @request,
          metadata: { delivery: @delivery, path: path, expires_at: @link.invite_expires_at.iso8601 })
        Invite::Result.new(link: @link, token: credentials.token, code: credentials.code, path: path, email_status: nil)
      end
      revoke_best_effort(superseded_invitation) if superseded_invitation
      return result unless @delivery == "email"

      result.with(email_status: InviteEmail.deliver(link: result.link, token: result.token, path: result.path))
    end

    private

    # The pending login stays on the link (a later sign-up reuses it), but
    # nothing started for the old generation can bind it.
    def retire_pending_sign_up!(user)
      return unless user&.portal_employee? && user.awaiting_clerk_binding? && user.invite_nonce_digest.present?

      user.update!(invite_nonce_digest: nil, invite_nonce_expires_at: nil)
      user.clerk_invitation_id
    end

    def revoke_best_effort(invitation_id)
      result = @clerk.revoke_invitation(invitation_id)
      Rails.logger.warn("[EmployeeLinks::Resend] Could not revoke invitation #{invitation_id}") unless result[:success]
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::Resend] Could not revoke invitation #{invitation_id}: #{error.class}")
    end

    def check_email!(employee)
      Invite.new(employee: employee, actor: @actor, delivery: "email",
        confirm_same_person_email: @confirm_same_person_email, request: @request).send(:check_email!)
    end
  end
end
