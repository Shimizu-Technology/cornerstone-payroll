# frozen_string_literal: true

module EmployeeLinks
  # The employee half of binding a Clerk account in /auth/me. PayrollInvitation
  # calls it inside TenantScope.as_system and the user's row lock, in the same
  # transaction that binds the Clerk ID, so either both happen or neither does.
  module Bind
    module_function

    # Locks the link and re-checks it: still invited to this user, not
    # expired, not locked, the employee app on for its company, and a client
    # subdomain token's azp naming that same company.
    def lock_link(user, link_id, azp:)
      return unless link_id.is_a?(Integer) && link_id.between?(1, 2**63 - 1)

      link = EmployeeAccountLink.lock.find_by(id: link_id, user_id: user.id)
      now = Time.current
      return unless link&.invite_open?(now) && !link.activation_locked?(now) && link.claim_user_id.nil? && link.employee.active?
      return unless link.portal_enabled? && EmployeeLinks.origin_allows_company?(azp, link.company_id)

      link
    end

    def activate!(link, user, request:)
      now = Time.current
      emailed_to_this_address = link.invite_delivery == "email" && EmployeeLinks.same_email?(link.invite_email, user.email)
      link.update!(status: "active", activated_at: now, invite_token_digest: nil, invite_code_digest: nil,
        failed_activation_attempts: 0, activation_locked_at: nil, activation_locked_until: nil)
      save_contact_email(link, user, verified: emailed_to_this_address, now: now)
      EmployeeLinks.audit!(link, "activated", user: user, request: request, metadata: { via: link.invite_delivery })
    end

    # With no email on the record, or when the employee chose the sign-up
    # address for notices, it becomes the record's email. It counts as
    # confirmed only when the invite was emailed to that same address.
    def save_contact_email(link, user, verified:, now:)
      employee = link.employee
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
    rescue ActiveRecord::RecordInvalid
      # The login still binds; the record keeps its contact details and staff
      # can set them later.
      Rails.logger.warn("[EmployeeLinks::Bind] Contact email for link #{link.id} was not saved")
    end
  end
end
