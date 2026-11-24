# frozen_string_literal: true

module EmployeeLinks
  # Ends a link (revoked, with who, why and when) and, when it was an
  # employee-only person's last eligible link, deactivates their login and
  # ends their Clerk sessions (D12). Runs inside the caller's transaction and
  # company or system scope; Clerk calls happen after commit.
  module Close
    module_function

    def revoke!(link, reason:, actor: nil, audit_actor: nil, request: nil, now: Time.current)
      return link if link.revoked?

      previous_status = link.status
      pending = link.user if link.invited? && link.user&.awaiting_clerk_binding?
      link.update!(status: "revoked", revoked_at: now, revoked_by: actor, revoked_reason: reason,
        invite_token_digest: nil, invite_code_digest: nil)
      EmployeeLinks.side_effect_audit do
        EmployeeLinks.audit!(link, "revoked", user: actor, actor: audit_actor, request: request,
          metadata: { reason: reason, previous_status: previous_status })
      end
      if pending
        close_pending_login!(pending)
      elsif link.user
        deactivate_if_last!(link.user, closed_link: link, now: now)
      end
      link
    end

    # Former employees keep read-only access until former_access_until.
    def make_former!(link, termination_date:, actor: nil, audit_actor: nil, request: nil, now: Time.current)
      return link unless link.active?

      years = former_access_years(link.company)
      access_until = (termination_date + years.years).in_time_zone(PayrollBusinessClock::TIME_ZONE).end_of_day
      link.update!(status: "former", former_at: now, former_access_until: access_until)
      EmployeeLinks.side_effect_audit do
        EmployeeLinks.audit!(link, "made_former", user: actor, actor: audit_actor, request: request,
          metadata: { termination_date: termination_date.iso8601, former_access_until: access_until.iso8601,
                      former_access_years: years })
      end
      deactivate_if_last!(link.user, closed_link: link, now: now) if access_until <= now
      link
    end

    def former_access_years(company)
      years = CompanyFeatures.for(company).former_access_years
      range = OperatingProfileCatalog::FORMER_ACCESS_YEARS_RANGE
      years.is_a?(Integer) && range.cover?(years) ? years : OperatingProfileCatalog.default_for("employee_portal.former_access_years")
    end

    # Only employee-only logins close; staff and client logins keep working
    # and simply lose the link on the next request.
    # The audit row belongs to the company whose link closed, so it can be
    # written inside that company's scope.
    def deactivate_if_last!(user, closed_link:, now: Time.current)
      return unless user&.portal_employee? && user.active?
      return if remaining_access?(user, closed_link, now)

      user.lock!
      user.update!(active: false)
      EmployeeLinks.side_effect_audit do
        AuditLog.record!(
          user: nil, actor: Current.actor || AuditActor.system_job("Employee app access"),
          organization_id: user.organization_id, company_id: closed_link.company_id,
          action: "authentication#employee_login_deactivated", record_type: "users", record_id: user.id,
          subject_name: user.name, event_category: "security", metadata: { reason: "last_employee_link_closed" }
        )
      end
      user_id = user.id
      ActiveRecord.after_all_transactions_commit { RevokeEmployeeSessionsJob.perform_later(user_id) }
    end

    # Inside a company scope, other companies' links are invisible, and a
    # nested system scope is refused. The SECURITY DEFINER login link
    # decision answers instead: any other non-revoked link anywhere
    # (:conflict), or an answer it can't give (:unknown), keeps the login
    # open, and the daily ExpireEmployeeLinksJob, which sees everything,
    # closes it later if nothing eligible remains.
    def remaining_access?(user, closed_link, now)
      eligible = EmployeeAccountLink.where(user_id: user.id).portal_eligible.where.not(id: closed_link.id)
      return eligible.exists? unless TenantScope.current&.mode == "company"

      decision = EmployeeAccountLink.contact_email_link_decision(
        user_id: user.id, company_id: closed_link.company_id, allowed_employee_ids: [ closed_link.employee_id ]
      )
      %i[conflict unknown].include?(decision) || eligible.exists?
    end

    def close_pending_login!(pending)
      pending.lock!
      invitation_id = pending.clerk_invitation_id
      pending.update!(active: false, invite_nonce_digest: nil, invite_nonce_expires_at: nil)
      return if invitation_id.blank?

      ActiveRecord.after_all_transactions_commit { revoke_invitation_best_effort(invitation_id) }
    end

    def revoke_invitation_best_effort(invitation_id)
      result = ClerkInvitationService.new.revoke_invitation(invitation_id)
      Rails.logger.warn("[EmployeeLinks::Close] Could not revoke invitation #{invitation_id}") unless result[:success]
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::Close] Could not revoke invitation #{invitation_id}: #{error.class}")
    end
  end
end
