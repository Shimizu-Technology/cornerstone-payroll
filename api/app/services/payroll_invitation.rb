# frozen_string_literal: true

class PayrollInvitation
  class BindingRefused < StandardError; end

  NONCE_LIFETIME = 30.days
  NONCE_PATTERN = /\A[0-9a-f]{64}\z/
  ACCEPTED_MESSAGE = "Clerk already accepted this invitation. Ask the recipient to sign in. If they still cannot sign in, an organization or platform admin can verify and bind their Clerk user ID."

  def initialize(clerk: ClerkInvitationService.new)
    @clerk = clerk
  end

  def send_invite(user, redirect_url:, ignore_existing: false)
    return { success: false, error: "Clerk API not configured" } unless @clerk.configured?

    user.with_lock do
      unless user.awaiting_clerk_binding?
        next { success: false, error: "This account is no longer awaiting an invitation" }
      end

      if user.clerk_invitation_id.present?
        failure = close_previous_invitation(user.clerk_invitation_id)
        next failure if failure
      end

      nonce = SecureRandom.hex(32)
      result = @clerk.create_invitation(
        email: user.email,
        redirect_url: redirect_url,
        public_metadata: {
          role: user.role,
          organization_id: user.organization_id,
          payroll_user_id: user.id,
          payroll_invite_nonce: nonce
        },
        ignore_existing: ignore_existing
      )

      if result[:success]
        user.update!(
          clerk_invitation_id: result.fetch(:invitation_id),
          invite_nonce_digest: Digest::SHA256.hexdigest(nonce),
          invite_nonce_expires_at: NONCE_LIFETIME.from_now
        )
      end
      result
    end
  rescue ActiveRecord::RecordInvalid
    # Clerk sends no email itself. Delivery only starts after the local commit.
    { success: false, error: "Invitation could not be saved locally" }
  end

  def bind_from_metadata(subject, request:)
    metadata = @clerk.fetch_user(subject)&.fetch("public_metadata", nil)
    return unless metadata.is_a?(Hash)

    id = metadata["payroll_user_id"]
    nonce = metadata["payroll_invite_nonce"]
    return unless id.is_a?(Integer) && id.between?(1, 2**63 - 1)
    return unless nonce.is_a?(String) && NONCE_PATTERN.match?(nonce)

    user = User.find_by(id: id)
    return unless user

    user.with_lock do
      # A simultaneous request can complete this exact binding first.
      next user if user.clerk_id == subject
      next unless user.awaiting_clerk_binding? && user.payroll_access_allowed?
      next unless user.invite_nonce_expires_at && user.invite_nonce_expires_at > Time.current
      next unless ActiveSupport::SecurityUtils.secure_compare(user.invite_nonce_digest.to_s, Digest::SHA256.hexdigest(nonce))
      next unless @clerk.invitation_status(user.clerk_invitation_id) == "accepted"

      bind!(user, subject, actor: user, request: request, source: "invitation_metadata")
      user
    end
  rescue ActiveRecord::RecordNotUnique
    # Only resume the exact same binding if it won the race.
    User.find_by(id: id, clerk_id: subject)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
    nil
  end

  def recover!(user, subject, actor:, request:)
    unless @clerk.fetch_user(subject)
      raise BindingRefused, "Clerk user ID could not be verified"
    end

    user.with_lock do
      unless user.awaiting_clerk_binding? && !user.platform_owner? &&
        (actor.super_admin? || (actor.org_admin? && user.organization_id == actor.organization_id && !user.super_admin?))
        raise BindingRefused, "This account cannot be bound through invitation recovery"
      end

      bind!(user, subject, actor: actor, request: request, source: "staff_recovery")
    end
  rescue ActiveRecord::RecordNotUnique
    raise BindingRefused, "This Clerk user ID is already bound"
  end

  private

  def close_previous_invitation(invitation_id)
    case @clerk.invitation_status(invitation_id)
    when "accepted"
      return { success: false, error: ACCEPTED_MESSAGE }
    when "expired", "revoked"
      return
    when "pending"
      # Acceptance can race this request. Only rotate once Clerk confirms revocation.
      result = @clerk.revoke_invitation(invitation_id)
      return if result[:success]
      return { success: false, error: ACCEPTED_MESSAGE } if result[:error_code] == "invitation_already_accepted"
    end

    { success: false, error: "Could not confirm the previous invitation is closed. Its sign-in details were preserved. Try again or contact an administrator." }
  end

  def bind!(user, subject, actor:, request:, source:)
    user.update!(clerk_id: subject, invitation_status: "accepted", invite_nonce_digest: nil, invite_nonce_expires_at: nil)
    AuditLog.record!(
      user: actor, organization_id: user.organization_id, company_id: user.company_id,
      action: "authentication#clerk_identity_bound", record_type: "users", record_id: user.id,
      subject_name: user.name, event_category: "security", metadata: { source: source, clerk_id: subject },
      ip_address: request.remote_ip, user_agent: request.user_agent, request_id: request.request_id
    )
  end
end
