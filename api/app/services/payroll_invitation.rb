# frozen_string_literal: true

class PayrollInvitation
  class BindingRefused < StandardError; end

  NONCE_LIFETIME = 30.days
  INVITATION_FIELDS = %w[email role organization_id company_id practice_company_id active clerk_id
    invitation_status clerk_invitation_id invite_nonce_digest invite_nonce_expires_at].freeze
  ADMIN_ROLES = %w[admin org_admin super_admin].freeze
  NONCE_PATTERN = /\A[0-9a-f]{64}\z/
  # Doesn't block a foreign-key check from a row that references the user
  # (see the lock order in EmployeeLinks).
  LOGIN_LOCK = "FOR NO KEY UPDATE"
  BIND_ATTEMPTS = 3
  ACCEPTED_MESSAGE = "Clerk already accepted this invitation. Ask the recipient to sign in. If they still cannot sign in, an organization or platform admin can verify and bind their Clerk user ID."

  def initialize(clerk: ClerkInvitationService.new)
    @clerk = clerk
  end

  # attributes: changes to the user (an employee sign-up's new email or
  # name) that are saved only together with the replacement invitation, after
  # Clerk confirmed the previous one closed. The block, if given, runs under
  # the user's lock just before that save; a false answer saves nothing and
  # revokes the new invitation.
  # A failure says what became of the login's previous invitation when it
  # matters to the caller: previous_invitation: :kept (still open, nothing
  # closed it) or :accepted (someone already accepted it).
  def send_invite(user, redirect_url:, ignore_existing: false, metadata: {}, attributes: {}, &commit)
    return { success: false, error: "Clerk API not configured", previous_invitation: :kept } unless @clerk.configured?

    user.reload
    return invitation_changed.merge(previous_invitation: :kept) unless user.awaiting_clerk_binding?

    snapshot = user.attributes.slice(*INVITATION_FIELDS)
    email = attributes.fetch(:email, snapshot.fetch("email"))
    # A demo login is invited only at an allow-listed address, checked before
    # any token or Clerk invitation exists and before an earlier one is closed.
    demo_company = DemoOutbound.demo_company_for(user)
    if demo_company && !DemoOutbound.permit?(company: demo_company, email: email, channel: "payroll_invitation", user: user)
      return { success: false, error: Company::DEMO_RECIPIENT_REFUSED_MESSAGE, refused: :recipient_not_allowed }
    end
    if user.clerk_invitation_id.present?
      failure = close_previous_invitation(user.clerk_invitation_id)
      return failure if failure
    end

    nonce = SecureRandom.hex(32)
    result = DemoOutbound.scoped(demo_company) do
      @clerk.create_invitation(
        email: email,
        redirect_url: redirect_url,
        public_metadata: metadata.merge(
          role: snapshot.fetch("role"),
          organization_id: snapshot.fetch("organization_id"),
          payroll_user_id: user.id,
          payroll_invite_nonce: nonce
        ),
        ignore_existing: ignore_existing
      )
    end
    return result unless result[:success]

    invitation_id = result.fetch(:invitation_id)
    saved = user.with_lock(LOGIN_LOCK) do
      next false unless user.attributes.slice(*INVITATION_FIELDS) == snapshot
      next false if commit && !commit.call(user)

      user.update!(attributes.merge(
        clerk_invitation_id: invitation_id,
        invite_nonce_digest: Digest::SHA256.hexdigest(nonce),
        invite_nonce_expires_at: NONCE_LIFETIME.from_now
      ))
      true
    end
    saved ? result : invitation_changed
  rescue ActiveRecord::RecordNotUnique
    { success: false, error: "That email address already has a login", conflict: :email_taken }
  rescue ActiveRecord::RecordInvalid
    { success: false, error: "Invitation could not be saved locally" }
  rescue ActiveRecord::RecordNotFound
    invitation_changed
  ensure
    revoke_best_effort(invitation_id, email: email) if invitation_id && !saved
  end

  def bind_from_metadata(subject, request:, azp: nil, &mfa_check)
    clerk_user = @clerk.fetch_user(subject)
    metadata = clerk_user&.fetch("public_metadata", nil)
    return unless metadata.is_a?(Hash)

    id = metadata["payroll_user_id"]
    nonce = metadata["payroll_invite_nonce"]
    return unless id.is_a?(Integer) && id.between?(1, 2**63 - 1)
    return unless nonce.is_a?(String) && NONCE_PATTERN.match?(nonce)

    user = User.find_by(id: id)
    return unless user

    return user if user.clerk_id == subject

    digest = Digest::SHA256.hexdigest(nonce)
    return unless nonce_matches?(user, digest)
    return unless user.payroll_access_allowed?

    invitation_id = user.clerk_invitation_id
    return unless @clerk.invitation_status(invitation_id) == "accepted"

    binding = { subject: subject, digest: digest, invitation_id: invitation_id, metadata: metadata,
                identity: ClerkInvitationService.email_summary(clerk_user), azp: azp, request: request }
    # The lock order is shared with every employee link path, so a deadlock
    # is only a backstop; the locked block re-checks everything on a retry.
    attempts = 0
    begin
      locked_bind(user, binding, &mfa_check)
    rescue ActiveRecord::Deadlocked
      attempts += 1
      retry if attempts < BIND_ATTEMPTS && retry_after_deadlock?
      nil
    end
  rescue ActiveRecord::RecordNotUnique
    # Only resume the exact same binding if it won the race.
    User.find_by(id: id, clerk_id: subject)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, BindingRefused
    # A refused binding answers like any other unbound account.
    nil
  end

  def self.recoverable_by?(user, actor)
    # Employee app logins bind only through their link (EmployeeLinks::Bind).
    user.awaiting_clerk_binding? && !user.platform_owner? && !user.portal_employee? &&
      (actor.super_admin? || (actor.org_admin? && user.organization_id == actor.organization_id && ADMIN_ROLES.exclude?(user.role)))
  end

  def recovery_account(user, subject, actor:)
    ensure_recoverable!(user, actor)
    @clerk.recovery_account(subject) || raise(BindingRefused, "Clerk user ID could not be verified")
  end

  def recover!(user, subject, confirm_email:, actor:, request:)
    account = recovery_account(user, subject, actor: actor)
    unless confirm_email.is_a?(String) && account.fetch(:verified_emails).any? { |email| email.casecmp?(confirm_email.strip) }
      raise BindingRefused, "Confirm one of this Clerk account's verified email addresses"
    end

    refuse_demo_binding!(user, [ user.email, confirm_email, account[:primary_email] ], channel: "payroll_invitation_recovery")

    invitation_id = user.with_lock do
      ensure_recoverable!(user, actor)
      previous_id = user.clerk_invitation_id
      bind!(user, subject, actor: actor, request: request, source: "staff_recovery",
        clerk_primary_email: account.fetch(:primary_email))
      user.update!(clerk_invitation_id: nil) if previous_id.present?
      previous_id
    end
    revoke_best_effort(invitation_id) if invitation_id.present?
  rescue ActiveRecord::RecordNotUnique
    raise BindingRefused, "This Clerk user ID is already bound"
  end

  # Makes sure a Clerk invitation can't be accepted any more: :closed (it
  # expired, was revoked, is gone, or was revoked now), :accepted (someone
  # already created a Clerk account with it), or :unconfirmed (Clerk couldn't
  # be asked or refused). A pending invitation counts as closed only once
  # Clerk confirms its revocation, because acceptance can race this call.
  def close_invitation(invitation_id)
    case @clerk.invitation_status(invitation_id)
    when "accepted" then :accepted
    when "expired", "revoked", :not_found then :closed
    when "pending"
      result = @clerk.revoke_invitation(invitation_id)
      return :closed if result[:success]

      result[:error_code] == "invitation_already_accepted" ? :accepted : :unconfirmed
    else
      :unconfirmed
    end
  end

  private

  def locked_bind(user, binding)
    subject = binding.fetch(:subject)
    request = binding.fetch(:request)
    user.with_lock(LOGIN_LOCK) do
      # A simultaneous request can complete this exact binding first.
      next user if user.clerk_id == subject
      next unless user.clerk_invitation_id == binding.fetch(:invitation_id) && nonce_matches?(user, binding.fetch(:digest))
      next unless user.active? && (user.super_admin? || user.organization&.active?)
      next if user.practice_company_id? && !user.practice_portal_open?
      next if user.portal_employee? && !invited_identity?(user, binding.fetch(:identity))
      refuse_demo_binding!(user, [ user.email, verified_primary_email(binding.fetch(:identity)) ], channel: "payroll_invitation_bind")

      # Check MFA against the locked invitation owner before binding or writing its audit.
      next if block_given? && !yield(user)

      # An employee app login binds only together with its still-open link,
      # in this one transaction (EmployeeLinks::Bind).
      bound = TenantScope.as_system(reason: "Bind authorized Clerk invitation") do
        link = EmployeeLinks::Bind.lock_link(user, binding.fetch(:metadata), azp: binding.fetch(:azp)) if user.portal_employee?
        next false if user.portal_employee? && !link

        bind!(user, subject, actor: user, request: request, source: "invitation_metadata")
        EmployeeLinks::Bind.activate!(link, user, request: request, identity: binding.fetch(:identity)) if link
        true
      end
      user if bound
    end
  end

  # A demo login binds only when every address involved is allow-listed: the
  # login's own email and the Clerk account's verified primary email.
  def refuse_demo_binding!(user, emails, channel:)
    company = DemoOutbound.demo_company_for(user)
    return unless company

    allowed = emails.all? { |email| email.present? && DemoOutbound.permit?(company: company, email: email, channel: channel, user: user) }
    raise BindingRefused, Company::DEMO_RECIPIENT_REFUSED_MESSAGE unless allowed
  end

  def verified_primary_email(identity)
    identity[:primary_email] if identity[:primary_verified]
  end

  # A deadlock rolled back the whole transaction, which is safe to run again
  # only when this method owns it (an /auth/me request does).
  def retry_after_deadlock?
    !ApplicationRecord.connection.transaction_open?
  end

  # An employee sign-up binds only the Clerk account made for its invited
  # address: the login's email must be that account's verified primary.
  def invited_identity?(user, identity)
    identity[:primary_verified] && EmployeeLinks.same_email?(identity[:primary_email], user.email)
  end

  def invitation_changed
    { success: false, error: "This account changed while preparing the invitation. Refresh and try again if it is still pending." }
  end

  def ensure_recoverable!(user, actor)
    return if self.class.recoverable_by?(user, actor)

    raise BindingRefused, "This account cannot be bound through invitation recovery"
  end

  def nonce_matches?(user, digest)
    user.awaiting_clerk_binding? && user.invite_nonce_expires_at && user.invite_nonce_expires_at > Time.current &&
      ActiveSupport::SecurityUtils.secure_compare(user.invite_nonce_digest.to_s, digest)
  end

  def revoke_best_effort(invitation_id, email: nil)
    result = email ? @clerk.revoke_invitation(invitation_id, email: email) : @clerk.revoke_invitation(invitation_id)
    return if result[:success]

    Rails.logger.warn("[PayrollInvitation] Could not revoke invitation #{invitation_id}: #{result[:error_code] || result[:status] || 'request failed'}")
  rescue StandardError => error
    Rails.logger.warn("[PayrollInvitation] Could not revoke invitation #{invitation_id}: #{error.class}")
  end

  def close_previous_invitation(invitation_id)
    case close_invitation(invitation_id)
    when :closed then nil
    when :accepted then { success: false, error: ACCEPTED_MESSAGE, previous_invitation: :accepted }
    else
      { success: false, error: "Could not confirm the previous invitation is closed. Its sign-in details were preserved. Try again or contact an administrator.",
        previous_invitation: :kept }
    end
  end

  def bind!(user, subject, actor:, request:, source:, **metadata)
    user.update!(clerk_id: subject, invitation_status: "accepted", invite_nonce_digest: nil, invite_nonce_expires_at: nil)
    AuditLog.record!(
      user: actor, organization_id: user.organization_id, company_id: user.company_id,
      action: "authentication#clerk_identity_bound", record_type: "users", record_id: user.id,
      subject_name: user.name, event_category: "security", metadata: metadata.merge(source: source, clerk_id: subject),
      ip_address: request.remote_ip, user_agent: request.user_agent, request_id: request.request_id
    )
  end
end
