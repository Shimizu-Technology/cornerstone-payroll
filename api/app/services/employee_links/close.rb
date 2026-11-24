# frozen_string_literal: true

module EmployeeLinks
  # Ends a link (revoked, with who, why and when) and, when it was an
  # employee-only person's last eligible link, deactivates their login and
  # ends their Clerk sessions (D12). Runs inside the caller's transaction and
  # company or system scope; Clerk calls happen after commit.
  #
  # Callers lock the link's login before the link (lock_link_and_login!, or
  # Retire.open_links), per the EmployeeLinks lock order. Every change that
  # can make a login's last eligible link go away holds that login's lock, so
  # two closes for one login run one after the other and the second sees the
  # first's result.
  module Close
    module_function

    # Locks the link's login, then the link, and re-reads both. False when
    # the link's login changed in between (the caller retries or refuses).
    def lock_link_and_login!(link)
      user_id = EmployeeAccountLink.where(id: link.id).pick(:user_id)
      EmployeeLinks.lock_users!([ user_id ])
      link.lock!
      link.association(:user).reset
      link.user_id == user_id
    end

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
        close_pending_login!(pending, now: now)
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
    #
    # closed_link: the link that just closed (nil for the daily sweep, which
    # counts every link). audit_company_id: where the audit row is written,
    # so it fits the caller's company scope.
    def deactivate_if_last!(user, closed_link:, now: Time.current, audit_company_id: closed_link&.company_id)
      return unless user&.portal_employee?

      # Usually already held by the caller; re-read under it either way.
      user = EmployeeLinks.lock_users!([ user.id ]).first
      return unless user&.active?
      return if remaining_access?(user, closed_link, now)

      user.update!(active: false, deactivated_at: now, deactivation_reason: "last_employee_link_closed")
      EmployeeLinks.side_effect_audit do
        AuditLog.record!(
          user: nil, actor: Current.actor || AuditActor.system_job("Employee app access"),
          organization_id: user.organization_id, company_id: audit_company_id,
          action: "authentication#employee_login_deactivated", record_type: "users", record_id: user.id,
          subject_name: user.name, event_category: "security", metadata: { reason: "last_employee_link_closed" }
        )
      end
      user_id = user.id
      closed_at = now.iso8601(6)
      ActiveRecord.after_all_transactions_commit { RevokeEmployeeSessionsJob.perform_later(user_id, closed_at) }
    end

    # Eligible means usable right now: active, or former with access still
    # running. Outside a company scope every link is visible. Inside one,
    # other companies' links are hidden and a nested system scope is refused,
    # so the narrow SECURITY DEFINER check answers (only true or false);
    # when it can't answer, the login stays open and the daily
    # ExpireEmployeeLinksJob, which sees everything, closes it.
    def remaining_access?(user, closed_link, now)
      eligible = EmployeeAccountLink.where(user_id: user.id)
        .where("status = 'active' OR (status = 'former' AND former_access_until > ?)", now)
      eligible = eligible.where.not(id: closed_link.id) if closed_link
      return eligible.exists? unless TenantScope.current&.mode == "company"

      answer = EmployeeAccountLink.login_has_eligible_link?(user_id: user.id, except_link_id: closed_link&.id, now: now)
      answer.nil? || answer || eligible.exists?
    end

    # A sign-up nobody finished: the pending login is closed and its email
    # stays reserved for this same employee, so a later invite reuses the row
    # (Activate) instead of finding the address taken.
    def close_pending_login!(pending, now: Time.current)
      pending = EmployeeLinks.lock_users!([ pending.id ]).first
      return unless pending&.awaiting_clerk_binding?

      invitation_id = pending.clerk_invitation_id
      pending.update!(active: false, invite_nonce_digest: nil, invite_nonce_expires_at: nil,
        deactivated_at: now, deactivation_reason: "pending_sign_up_closed")
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
