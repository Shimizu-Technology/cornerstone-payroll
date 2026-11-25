# frozen_string_literal: true

module EmployeeLinks
  # The employee half of binding a Clerk account in /auth/me. PayrollInvitation
  # calls it inside TenantScope.as_system and the user's row lock, in the same
  # transaction that binds the Clerk ID, so either both happen or neither does.
  module Bind
    # Clerk verification strategies where the person proved they receive mail
    # at the address (a code, a link, or an email provider's sign-in).
    PROVEN_STRATEGIES = /\A(?:email_code|email_link|from_oauth_[a-z_]+)\z/

    module_function

    # Locks the link (after the user, per the EmployeeLinks lock order) and
    # re-checks it: still invited to this user, for the same invite generation
    # the Clerk invitation was made for (a resend retires older ones), not
    # expired, not locked, the employee app on for its company, and a client
    # subdomain token's azp naming that same company.
    def lock_link(user, metadata, azp:)
      link_id = metadata["payroll_employee_link_id"]
      generation = metadata["payroll_invite_generation"]
      return unless link_id.is_a?(Integer) && link_id.between?(1, 2**63 - 1)
      return unless generation.is_a?(Integer) && generation.positive?

      link = EmployeeAccountLink.lock.find_by(id: link_id, user_id: user.id)
      now = Time.current
      return unless link&.invite_open?(now) && link.invite_generation == generation
      return unless !link.activation_locked?(now) && link.claim_user_id.nil? && link.employee.active?
      return unless link.portal_enabled? && EmployeeLinks.origin_allows_company?(azp, link.company_id)
      return unless EmployeeLinks.demo_boundary_allows?(user, link.company)
      return unless EmployeeLinks.demo_request_allowed?(link.company, azp)
      # A demo login binds only with an allow-listed sign-in address, which
      # also covers printed-code sign-ups.
      return unless DemoOutbound.permit?(company: link.company, email: user.email, channel: "employee_link_bind", user: user)

      link
    end

    def activate!(link, user, request:, identity:)
      now = Time.current
      link.update!(status: "active", activated_at: now, invite_token_digest: nil, invite_code_digest: nil,
        failed_activation_attempts: 0, activation_locked_at: nil, activation_locked_until: nil)
      save_contact_email(link, user, verified: email_proven?(link, user, identity), now: now)
      EmployeeLinks.audit!(link, "activated", user: user, request: request, metadata: { via: link.invite_delivery })
    end

    # The sign-up address counts as confirmed only on evidence from the bound
    # Clerk account: Clerk verified it by a code, a link or an email
    # provider, or by the invitation ticket when the invite token itself was
    # emailed to that same address (opening it proved the inbox). A ticket
    # alone, as after a printed code, proves nothing about the inbox.
    def email_proven?(link, user, identity)
      strategy = identity.fetch(:verification_strategies, {})[EmployeeLinks.normalized_email(user.email)]
      return false if strategy.nil?
      return true if PROVEN_STRATEGIES.match?(strategy)

      strategy == "ticket" && link.invite_delivery == "email" && EmployeeLinks.same_email?(link.invite_email, user.email)
    end

    # With no email on the record, or when the employee chose the sign-up
    # address for notices, it becomes the record's email. It is marked
    # confirmed only on proof (email_proven?).
    #
    # The employee row comes last in the lock order, so it is taken without
    # waiting: if a staff action holds it, the contact details stay as they
    # are and staff can set them later; the login still binds.
    def save_contact_email(link, user, verified:, now:)
      employee = Employee.transaction(requires_new: true) do
        Employee.lock("FOR UPDATE NOWAIT").find(link.employee_id)
      end
      use_sign_up_email = employee.email.blank? || link.sign_up_email_for_notices?
      if use_sign_up_email && !EmployeeLinks.same_email?(employee.email, user.email)
        validation = EmployeeContactValidator.new(employee: employee, company: link.company, email: user.email,
          actor: user, source: "employee").call
        return unless validation.valid?

        employee.assign_attributes(email: validation.normalized_email, contact_source: "employee")
      end
      if verified && EmployeeLinks.same_email?(employee.email, user.email) && employee.email_verified_at.nil?
        employee.email_verified_at = now
      end
      return unless employee.changed?

      Employee.transaction(requires_new: true) { employee.save! }
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::RecordInvalid
      Rails.logger.warn("[EmployeeLinks::Bind] Contact email for link #{link.id} was not saved")
    end
  end
end
