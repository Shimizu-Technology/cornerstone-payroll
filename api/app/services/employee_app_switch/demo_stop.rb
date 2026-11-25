# frozen_string_literal: true

module EmployeeAppSwitch
  # The demo kill switch: one action that turns every demo company's
  # employee app off (today and every later scheduled version, revoking the
  # activations), ends the early-access window, revokes pending demo
  # invitations (tickets), ends demo support views and employee-only demo
  # sessions, and so stops demo employee notifications (DemoOutbound refuses
  # employee mail while a demo's app is off, rechecked right before each
  # send). Data and audit history stay.
  #
  # Each company is stopped under its row lock, which invitation issuance
  # also takes (EmployeeLinks.with_issuance_lock), so no invitation is
  # issued halfway through a stop. Clerk revocations (pending sign-up
  # invitations and employee sessions) are recorded as
  # EmployeeAppClerkRevocation rows and retried until Clerk confirms; the
  # stop's audit lists what it did in the database (confirmed) separately
  # from what it asked Clerk to do (requested), and the job audits each
  # confirmation. A repeat stop finds the still-pending requests instead of
  # duplicating them, and queues a job for any pending row that has none
  # (RetryEmployeeAppClerkRevocationsJob does the same on a schedule).
  class DemoStop
    ACTION = "employee_app_switch#demo_stopped"

    def self.call(...)
      new(...).call
    end

    def initialize(organization:, actor:, reason:, now: Time.current)
      @organization = organization
      @actor = actor
      @reason = reason
      @now = now
    end

    def call
      reason = EmployeeAppSwitch.reason!(@reason)
      queued = []
      summary = ApplicationRecord.transaction do
        @organization.lock!
        EarlyAccess.authorize!(@actor, @organization)
        window = EmployeeAppEarlyAccessWindow.current_for(@organization.id)
        EarlyAccess.end_window!(window, @actor, "Demo employee access stopped: #{reason}") if window

        companies = Company.demo.where(organization_id: @organization.id).order(:id).to_a
        results = companies.map { |company| stop_company!(company, reason, queued) }
        result = { companies: results, early_access_window_ended: window.present? }
        audit!(nil, ACTION, @organization.name, { reason: reason, early_access_window_id: window&.id,
          companies: results.map { |row| row.slice(:company_id, :confirmed, :requested) } }.compact)
        result
      end
      # Clerk calls run after commit, like every other session revocation. A
      # pending row from an earlier stop whose job was never queued goes too.
      unqueued = EmployeeAppClerkRevocation.unqueued.where(organization_id: @organization.id).pluck(:id)
      EmployeeAppClerkRevocation.enqueue!(queued | unqueued)
      summary
    end

    private

    def stop_company!(company, reason, queued)
      company.with_lock do
        turned_off = EmployeeAppSwitch.on_anywhere(company)
        if turned_off.any?
          ProfileWriter.apply!(company: company, actor: @actor, values: KEYS.index_with(false),
            reason: "Demo employee access stopped: #{reason}")
        end

        invitations = []
        revoked = revoke_pending_invitations!(company, reason, invitations)
        views = end_support_views!(company)
        users = employee_only_logins(company)
        requested_invitations = invitations.filter_map do |invitation_id, user_id|
          request!(company, "invitation", invitation_id, user_id: user_id)
        end
        requested_sessions = users.filter_map { |user_id| request!(company, "sessions", user_id, user_id: user_id) }
        queued.concat(requested_invitations.map(&:id) + requested_sessions.map(&:id))

        confirmed = { turned_off: turned_off, invitations_revoked: revoked, support_views_ended: views }
        requested = { clerk_invitation_revocations: requested_invitations.size, clerk_session_revocations: requested_sessions.size,
                      already_pending: invitations.size + users.size - requested_invitations.size - requested_sessions.size }
        audit!(company, EmployeeAppSwitch::AUDIT_ACTION, company.name,
          { reason: reason, turned_on: [], turned_off: turned_off, demo_stop: true, confirmed: confirmed, requested: requested })
        { company_id: company.id, name: company.name, turned_off: turned_off, invitations_revoked: revoked,
          support_views_ended: views, sessions_ended: requested_sessions.size, confirmed: confirmed, requested: requested }
      end
    end

    def request!(company, kind, target, user_id:)
      EmployeeAppClerkRevocation.request!(kind: kind, target: target, organization: @organization, company: company,
        user: User.find_by(id: user_id), source: EmployeeAppClerkRevocation::SOURCE_DEMO_STOP, requested_by: @actor, now: @now)
    end

    def revoke_pending_invitations!(company, reason, invitations)
      EmployeeAccountLink.where(company_id: company.id, status: "invited").order(:id).to_a.count do |link|
        next false unless EmployeeLinks::Close.lock_link_and_login!(link)
        next false unless link.invited?

        EmployeeLinks::Close.revoke!(link, reason: "Demo employee access stopped: #{reason}", actor: @actor,
          invitation_revocations: invitations)
        true
      end
    end

    def end_support_views!(company)
      ViewAsGrant.where(company_id: company.id, ended_at: nil).where("expires_at > ?", @now).order(:id).to_a.count do |grant|
        grant.update!(ended_at: @now)
        grant.record_access!("view_as#ended", nil)
        true
      end
    end

    # Employee-only logins with a current demo link; staff and client logins
    # keep their own sessions and lose the employee app on the next request.
    def employee_only_logins(company)
      User.where(id: EmployeeAccountLink.where(company_id: company.id, status: %w[active former]).select(:user_id))
        .order(:id).select(&:portal_employee?).map(&:id)
    end

    def audit!(company, action, subject_name, metadata)
      record = lambda do
        AuditLog.record!(
          user: @actor, organization_id: @organization.id, company_id: company&.id, action: action,
          record_type: company ? "Company" : "Organization", record_id: company&.id || @organization.id,
          subject_name: subject_name, event_category: "security", metadata: metadata
        )
      end
      TenantScope.current ? record.call : TenantScope.as_system(reason: "Record the demo employee access stop", &record)
    end
  end
end
