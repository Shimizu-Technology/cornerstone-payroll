# frozen_string_literal: true

module EmployeeAppSwitch
  # The demo kill switch: one action that turns every demo company's
  # employee app off, ends the early-access window, revokes pending demo
  # invitations (tickets), ends demo support views and employee-only demo
  # sessions, and so stops demo employee notifications (DemoOutbound refuses
  # employee mail while a demo's app is off). Data and audit history stay.
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
      sessions = []
      summary = ApplicationRecord.transaction do
        @organization.lock!
        EarlyAccess.authorize!(@actor, @organization)
        window = EmployeeAppEarlyAccessWindow.current_for(@organization.id)
        EarlyAccess.end_window!(window, @actor, "Demo employee access stopped: #{reason}") if window

        companies = Company.demo.where(organization_id: @organization.id).order(:id).to_a
        results = companies.map { |company| stop_company!(company, reason, sessions) }
        result = { companies: results, early_access_window_ended: window.present? }
        audit!(nil, ACTION, @organization.name, { reason: reason, early_access_window_id: window&.id,
          companies: results.map { |row| row.slice(:company_id, :turned_off, :invitations_revoked, :support_views_ended, :sessions_ended) } }.compact)
        result
      end
      # Clerk calls run after commit, like every other session revocation.
      sessions.uniq.each { |user_id| RevokeEmployeeSessionsJob.perform_later(user_id, @now.iso8601) }
      summary
    end

    private

    def stop_company!(company, reason, sessions)
      company.with_lock do
        before = EmployeeAppSwitch.stored_values(company)
        scheduled = company.client_operating_profiles.where("effective_on > ?", PayrollBusinessClock.today)
          .order(:effective_on, :id).any? { |profile| KEYS.any? { |key| profile_value(profile, key) } }
        turned_off = KEYS.select { |key| before[key] }
        if turned_off.any? || scheduled
          ProfileWriter.apply!(company: company, actor: @actor, values: KEYS.index_with(false),
            reason: "Demo employee access stopped: #{reason}")
        end

        revoked = revoke_pending_invitations!(company, reason)
        views = end_support_views!(company)
        users = employee_only_logins(company)
        sessions.concat(users)
        row = { company_id: company.id, name: company.name, turned_off: turned_off, invitations_revoked: revoked,
                support_views_ended: views, sessions_ended: users.size }
        audit!(company, EmployeeAppSwitch::AUDIT_ACTION, company.name,
          { reason: reason, turned_on: [], turned_off: turned_off, demo_stop: true,
            invitations_revoked: revoked, support_views_ended: views, sessions_ended: users.size })
        row
      end
    end

    def profile_value(profile, key)
      (key == MASTER ? profile.employee_portal_enabled : profile.option_value(key)) == true
    end

    def revoke_pending_invitations!(company, reason)
      EmployeeAccountLink.where(company_id: company.id, status: "invited").order(:id).to_a.count do |link|
        next false unless EmployeeLinks::Close.lock_link_and_login!(link)
        next false unless link.invited?

        EmployeeLinks::Close.revoke!(link, reason: "Demo employee access stopped: #{reason}", actor: @actor)
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
