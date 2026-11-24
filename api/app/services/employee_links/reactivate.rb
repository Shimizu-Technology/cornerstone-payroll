# frozen_string_literal: true

module EmployeeLinks
  # The one step a deactivated employee-only login may take
  # (POST /api/v1/employee/links/reactivate): a rehired person whose
  # portal_employee login closed with their last link. The same check as
  # sign-up (token or code, DOB, SSN-4) plus a fresh sign-in to their existing
  # Clerk account (the M4-1 step-up, enforced by the controller). Only then
  # are the same login reactivated and the new link bound, in one
  # transaction; any failed check leaves both inactive. The old link stays
  # closed. Staff and client logins were never deactivated and use Claim.
  class Reactivate < Claim
    def self.eligible_login?(user, employee)
      user.portal_employee? && !user.active? && user.clerk_id.present? && !user.clerk_id.start_with?("pending_") &&
        user.invitation_status == "accepted" && user.organization&.active? && user.practice_company_id.nil? &&
        EmployeeAccountLink.where(user_id: user.id, employee_id: [ employee.id, employee.previous_employee_id ].compact,
          status: %w[former revoked]).exists?
    end

    private

    def user_allowed?
      @user.is_a?(User) && @user.portal_employee? && !@user.active?
    end

    # The earlier link to this same employee record (or the record it
    # replaced) is what shows it's the same person.
    def same_person?(link)
      self.class.eligible_login?(@user, link.employee)
    end

    def attach!(link)
      @user.lock!
      @user.update!(active: true)
      super
      AuditLog.record!(
        user: @user, organization_id: @user.organization_id, company_id: link.company_id,
        action: "authentication#employee_login_reactivated", record_type: "users", record_id: @user.id,
        subject_name: @user.name, event_category: "security", metadata: { employee_account_link_id: link.id },
        ip_address: @request&.remote_ip, user_agent: @request&.user_agent, request_id: @request&.request_id
      )
    end

    def audit_action
      "reactivated"
    end
  end
end
