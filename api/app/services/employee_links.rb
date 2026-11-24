# frozen_string_literal: true

# The employee app link lifecycle (M4-2): invite, sign-up, claim, bind and
# their audits. Staff-facing errors are EmployeeLinks::Error; everything an
# employee sees before they are signed in is one generic answer.
#
# Lock order, the same on every path that changes links or their logins
# (invite, resend, sign-up, bind, claim, and later retire, revoke and the
# expiry sweep):
#
#   1. the employee row, by staff actions that change the employee;
#   2. logins (users), lowest id first, FOR NO KEY UPDATE, so a link's
#      foreign-key check on its login never waits behind them;
#   3. links.
#
# A path that starts from a link reads it first without a lock, locks its
# login, then locks the link and re-checks that its login didn't change.
# Binding writes the employee's contact email last, without waiting: if a
# staff action holds the employee row, the contact email isn't changed (the
# login still binds). Clerk calls always happen outside transactions.
module EmployeeLinks
  class Error < StandardError; end
  class Forbidden < Error; end

  AUDIT_RECORD_TYPE = "employee_account_links"

  # Inviting, resending and unlocking stay with Cornerstone staff who can
  # change client configuration until M4-9 adds the client admin path.
  def self.require_staff!(actor, company)
    allowed = actor.is_a?(User) && actor.payroll_access_allowed? && actor.staff_member? &&
      actor.can_access_company?(company.id) &&
      StaffRolePolicy.allowed?(actor, :manage_client_configuration, company: company)
    raise Forbidden, "Client configuration access required" unless allowed
  end

  def self.audit!(link, action, user: nil, actor: nil, metadata: {}, request: nil)
    AuditLog.record!(
      user: user, actor: actor || (AuditActor.for_user(user) if user),
      organization_id: link.company.organization_id, company_id: link.company_id,
      action: "employee_links##{action}", record_type: AUDIT_RECORD_TYPE, record_id: link.id,
      subject_name: link.employee.display_name, event_category: "security",
      metadata: metadata.compact,
      ip_address: request&.remote_ip || Current.ip_address,
      user_agent: request&.user_agent || Current.user_agent,
      request_id: request&.request_id || Current.request_id
    )
  end

  # sign_up: a new account; claim: sign in with an existing login;
  # reactivate: sign in again to a login that closed with an earlier link.
  def self.invite_path(claim_user)
    return "sign_up" unless claim_user

    claim_user.active? ? "claim" : "reactivate"
  end

  # Link changes made as a side effect of another action (a termination, a
  # status change) are audited without suppressing that action's own audit.
  def self.side_effect_audit
    previous = Current.domain_audit_recorded
    yield
  ensure
    Current.domain_audit_recorded = previous
  end

  def self.lock_users!(ids)
    ids = Array(ids).compact.uniq.sort
    return [] if ids.empty?

    User.where(id: ids).order(:id).lock("FOR NO KEY UPDATE").to_a
  end

  def self.verifier_actor
    AuditActor.system_job("Employee app sign-up check")
  end

  def self.normalized_email(value)
    EmployeeContactValidator.normalize_email(value)
  end

  def self.same_email?(left, right)
    a = normalized_email(left)
    a.present? && a == normalized_email(right)
  end

  def self.email_format?(email)
    email.is_a?(String) && email.length <= EmployeeContactValidator::MAX_EMAIL_LENGTH && !email.include?("..") &&
      email.match?(URI::MailTo::EMAIL_REGEXP) && email.match?(EmployeeContactValidator::EMAIL_FORMAT_PATTERN)
  end

  def self.login_email_taken?(email, except_user_id: nil)
    scope = User.where(EmployeeContactValidator.normalized_email_node(User.arel_table[:email]).eq(normalized_email(email)))
    scope = scope.where.not(id: except_user_id) if except_user_id
    scope.exists?
  end

  # A link to a client subdomain belongs to that subdomain's company only.
  def self.origin_allows_company?(azp, company_id)
    return true unless TenantSubdomainRegistry.client_origin?(azp)

    TenantSubdomainRegistry.enabled_origin_company_id(azp) == company_id
  end
end
