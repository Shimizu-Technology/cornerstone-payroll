# frozen_string_literal: true

# Current for the employee portal controllers, which don't inherit
# ApplicationController: reset after every request, request details always,
# and the signed-in user and actor once one is known.
module EmployeePortalRequestContext
  extend ActiveSupport::Concern

  included do
    around_action :reset_employee_portal_context, prepend: true
  end

  private

  def reset_employee_portal_context
    Current.request_id = request.request_id
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
    yield
  ensure
    Current.reset
  end

  def set_current_employee_user(user)
    Current.user = user
    Current.actor = AuditActor.for_user(user)
    Current.organization_id = user.organization_id
  end

  # Same Clerk checks as the link-scoped controller; nil on any failure.
  def verified_employee_portal_user
    token = request.headers["Authorization"].to_s[/\ABearer (\S+)\z/, 1]
    return unless token

    @clerk_token_payload = ClerkTokenVerifier.new.verify(token)
    subject = @clerk_token_payload&.fetch("sub", nil)
    return unless subject.is_a?(String) && subject.present? && !subject.start_with?("pending_")

    user = User.find_by(clerk_id: subject)
    return unless user && StagingOutboundPolicy.tester?(user_id: user.id, email: user.email, id: subject)
    # An inactive login this route refuses anyway never costs a Clerk call.
    return unless user.payroll_access_allowed? || reactivating_login?(user)

    # A session from before the login was deactivated never works again.
    if EmployeeLinks::SessionFence.fenced?(user, @clerk_token_payload)
      @employee_session_fenced = true
      return
    end

    user
  end

  # True after verified_employee_portal_user refused only because the
  # session predates the login's closure: the person must sign in again.
  def employee_session_fenced?
    @employee_session_fenced == true
  end

  def reactivating_login?(user)
    allow_deactivated_employee_login? && user.portal_employee? && !user.active? &&
      user.deactivation_reason == "last_employee_link_closed" &&
      user.invitation_status == "accepted" && user.organization&.active? && EmployeeLinks.demo_login_allowed?(user)
  end

  # Only the rehire reactivation route accepts a deactivated employee-only
  # login, and only to run its one check (EmployeeLinks::Reactivate).
  def allow_deactivated_employee_login?
    false
  end
end
