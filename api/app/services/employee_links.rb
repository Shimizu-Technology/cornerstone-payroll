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
  # A resend found that the person already created their Clerk account from
  # the open sign-up (it isn't bound yet), so nothing was rotated.
  class SignUpAccepted < Error; end

  AUDIT_RECORD_TYPE = "employee_account_links"

  def self.staff_management_allowed?(actor, company)
    actor.is_a?(User) && actor.staff_member? && actor.payroll_access_allowed? &&
      actor.can_access_company?(company.id) &&
      StaffRolePolicy.allowed?(actor, :manage_client_configuration, company: company)
  end

  def self.require_staff!(actor, company)
    raise Forbidden, "Cornerstone staff access required" unless staff_management_allowed?(actor, company)
  end

  # Pilot capability: the client's own company users can manage invitations.
  # Unlocking, revoking and resetting sign-up still require staff management.
  def self.manage_invitations_allowed?(actor, company)
    staff_management_allowed?(actor, company) ||
      (actor.is_a?(User) && actor.client? && actor.payroll_access_allowed? && actor.can_access_company?(company.id))
  end

  def self.require_invitation_management!(actor, company)
    raise Forbidden, "Employee invitation access required" unless manage_invitations_allowed?(actor, company)
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

  # What closing a sign-up nobody finished writes to its pending login. Its
  # nonce is always cleared. A login that is still active closes now, with
  # the database's clock; one already closed (an admin's deactivation above
  # all) keeps its reason and time, so an admin-deactivated row never becomes
  # a reusable pending_sign_up_closed one.
  def self.pending_closure_attributes(pending)
    attributes = { invite_nonce_digest: nil, invite_nonce_expires_at: nil }
    return attributes unless pending.active?

    attributes.merge(active: false, deactivated_at: ApplicationRecord.database_now,
      deactivation_reason: "pending_sign_up_closed")
  end

  # A sign-up nobody finished, closed with its link: never bound, made for
  # this employee (or the record it replaced) at this company, and linked to
  # no other employee. Its email stays reserved for that person; a later
  # sign-up reuses the row instead of finding the address taken.
  def self.closed_pending_sign_up_for?(user, employee)
    return false unless user&.portal_employee? && !user.active? && user.awaiting_clerk_binding? &&
      user.deactivation_reason == "pending_sign_up_closed" && user.company_id == employee.company_id

    links = EmployeeAccountLink.where(user_id: user.id)
    links.exists? && !links.where.not(employee_id: [ employee.id, employee.previous_employee_id ].compact).exists?
  end

  def self.reusable_pending_login(email, employee)
    user = User.where(EmployeeContactValidator.normalized_email_node(User.arel_table[:email]).eq(normalized_email(email))).first
    user if closed_pending_sign_up_for?(user, employee)
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

  # Demo and live never mix in one login (D5), decided by the login's home
  # company: a demo company's links are open only to a login whose home is a
  # demo, and a live company's only to a login whose home is live. A leftover
  # assignment (say, from before a role change) never decides it.
  def self.demo_boundary_allows?(user, company)
    home = user&.company
    return false unless home && company

    company.demo? ? home.demo? : !home.demo?
  end

  # A login whose home company is a demo works only while its address is on
  # the allow-list (DemoOutbound); every other login is unaffected.
  def self.demo_login_allowed?(user)
    !user.company&.demo? || DemoOutbound.allowed?(user.email)
  end

  # The links a login can open from this origin: the employee app's list,
  # the link it opens (every link-scoped data request) and the /auth/me
  # count all use this. A demo link also needs a session from that demo's
  # own subdomain and the request-time demo gate, and a browser request's
  # Origin, when it sends one, must be that subdomain too (each link is
  # checked on its own), so outside it a demo link is neither listed,
  # counted nor opened.
  def self.openable_links(user, azp:, origin: nil)
    user.employee_account_links.portal_eligible.includes(company: :organization).order(:id)
      .select { |link| openable?(user, link, azp: azp, origin: origin) }
  end

  def self.openable?(user, link, azp:, origin: nil)
    !link.activation_locked? && link.portal_enabled? && origin_allows_company?(azp, link.company_id) &&
      demo_boundary_allows?(user, link.company) && demo_request_allowed?(link.company, azp) &&
      demo_origin_allowed?(link.company, origin)
  end

  # A request with no Origin header (not from a browser page) is judged by
  # its session alone; one that sends an Origin must send the demo's own.
  def self.demo_origin_allowed?(company, origin)
    origin.blank? || demo_request_allowed?(company, origin)
  end

  # Invitation issuance for a demo company holds the company row lock,
  # shared, which the demo kill switch takes exclusively (DemoStop), so an
  # invitation is never issued halfway through a stop. Call first inside the
  # issuing transaction, then re-check the employee app is on; that re-check
  # reads only the cached employee service answer while the lock is held.
  def self.lock_for_issuance!(company)
    return unless company&.demo?

    EmployeeAppSwitch::Enforcement.cached_attestation_only!
    Company.where(id: company.id).lock("FOR SHARE").pick(:id)
  end

  # A demo link's activation, claim, bind and data requests must come from
  # that demo company's own subdomain, and (under the early-access waiver)
  # this process must run the RLS guard in raise mode as the restricted role.
  def self.demo_request_allowed?(company, origin)
    return true unless company&.demo?

    TenantSubdomainRegistry.client_origin?(origin) && TenantSubdomainRegistry.enabled_origin_company_id(origin) == company.id &&
      EmployeeAppSwitch::Enforcement.demo_request_allowed?(company)
  end

  # A link to a client subdomain belongs to that subdomain's company only.
  def self.origin_allows_company?(azp, company_id)
    return true unless TenantSubdomainRegistry.client_origin?(azp)

    TenantSubdomainRegistry.enabled_origin_company_id(azp) == company_id
  end

  # Browser activation (when Origin is sent) must come from the invite
  # company's own subdomain when that company has an enabled subdomain, and
  # never from another client's subdomain. Requests without an Origin header
  # keep working for live companies (demos still require their own subdomain
  # via demo_request_allowed?).
  def self.activation_origin_allowed?(company, origin)
    return true if origin.blank?

    if AppUrl.subdomain_live?(company)
      return TenantSubdomainRegistry.client_origin?(origin) &&
        TenantSubdomainRegistry.enabled_origin_company_id(origin) == company.id
    end

    origin_allows_company?(origin, company.id)
  end
end
