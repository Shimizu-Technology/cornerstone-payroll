# frozen_string_literal: true

class ViewAsGrant < ApplicationRecord
  HEADER = "X-View-As-Grant"
  LIFETIME = 30.minutes
  STARTED_ACTION = "view_as#started"
  TOKEN_PATTERN = /\A[A-Za-z0-9_-]{43}\z/

  belongs_to :company
  belongs_to :staff_user, class_name: "User"
  belongs_to :target_user, class_name: "User", optional: true
  belongs_to :target_employee, class_name: "Employee", optional: true

  validates :mode, inclusion: { in: %w[view_only] }
  validates :reason, presence: true, length: { maximum: 500 }

  def self.ready?
    return true unless Rails.env.production?

    # Enable on both processes after the employee rollout readiness checks
    # pass, including the employee web health and published terms checks.
    ENV["VIEW_AS_READY"] == "true" && MfaPolicy.enabled? &&
      RlsContextGuard.mode == "raise" && ENV["CLERK_AUTHORIZED_PARTIES"].present?
  end

  def self.allowed_staff?(user)
    ready? && user&.super_admin? && user.view_as_allowed? && user.payroll_access_allowed?
  end

  def self.allowed_company?(user, company)
    company&.active? && company.organization.active? && company.organization_id == user.organization_id &&
      user.can_access_company?(company.id)
  end

  def self.find_for_token(token, user)
    return unless user && TOKEN_PATTERN.match?(token)

    TenantScope.as_system(reason: "Find the signed-in staff member's support grant") do
      find_by(staff_user_id: user.id, token_digest: Digest::SHA256.hexdigest(token), mode: "view_only")
    end
  end

  def open?
    ended_at.nil? && expires_at > Time.current
  end

  def employee_view?
    target_employee_id.present?
  end

  def client_target
    user = target_user
    return unless user&.client? && user.active? && user.organization_id == company.organization_id
    return if user.practice_company_id? && !user.practice_portal_open?

    user if user.can_access_company?(company_id)
  end

  def employee_context
    return unless employee_view? && company.live_payroll?

    features = CompanyFeatures.for(company)
    return unless features.employee_portal_enabled? && features.subdomain_enabled?
    return unless TenantSubdomainRegistry::SLUG_PATTERN.match?(company.subdomain_slug.to_s)

    employee = Employee.find_by(id: target_employee_id, company_id: company_id)
    ViewAsEmployeeContext.resolve(employee, company) if employee
  end

  def employee_origin
    "https://#{company.subdomain_slug}.#{TenantSubdomainRegistry::ROOT_DOMAIN}"
  end

  def record_access!(action, name)
    Current.set(real_user: staff_user, view_as_grant: self) do
      AuditLog.record!(
        user: staff_user, company_id: company_id, organization_id: company.organization_id,
        action: action, record_type: self.class.table_name, record_id: id, subject_name: name,
        event_category: "security", metadata: { mode: mode, target_type: employee_view? ? "employee" : "client" }
      )
    end
  end
end
