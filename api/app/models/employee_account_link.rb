# frozen_string_literal: true

class EmployeeAccountLink < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :company
  belongs_to :employee
  belongs_to :invited_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  enum :status, { invited: "invited", active: "active", former: "former", revoked: "revoked" }, validate: true

  validates :payroll_environment, inclusion: { in: %w[live] }
  validates :user, presence: true, if: -> { active? || former? }
  validates :invite_token_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :employee_belongs_to_live_company

  scope :portal_eligible, -> {
    where(status: "active").or(where(status: "former").where("former_access_until > ?", Time.current))
  }

  # Narrow decision lookup that returns only :conflict, :allowed or :none,
  # never records. A login linked to any other employee always returns
  # :conflict, even if an allowed link also exists.
  #
  # Outside a tenant scope it reads every company as a system read. Inside a
  # company scope it reads within that scope, because TenantScope refuses a
  # nested system read: once RLS is enforced, links at other companies are
  # not visible here until TenantScope supports one.
  def self.contact_email_link_decision(user_id:, company_id:, allowed_employee_ids: [])
    return :none if user_id.blank?

    allowed_ids = Array(allowed_employee_ids).filter_map { |id| Integer(id, exception: false) }.uniq
    target_company_id = Integer(company_id, exception: false)

    with_system_decision_read do
      scope = where(user_id: user_id).where.not(status: "revoked")
      if target_company_id.present? && allowed_ids.any?
        return :conflict if scope.where("company_id <> ? OR employee_id NOT IN (?)", target_company_id, allowed_ids).exists?
        return :allowed if scope.where(company_id: target_company_id, employee_id: allowed_ids).exists?

        return :none
      end

      scope.exists? ? :conflict : :none
    end
  end

  def self.with_system_decision_read(&block)
    return yield if !RlsContextGuard.enabled? || TenantScope.current

    TenantScope.as_system(reason: "Check cross-company employee account link decision", &block)
  end
  private_class_method :with_system_decision_read

  def portal_enabled?
    company.active? && company.organization.active? && CompanyFeatures.for(company).employee_portal_enabled?
  end

  private

  def employee_belongs_to_live_company
    errors.add(:company, "must run live payroll") if company && !company.live_payroll?
    errors.add(:employee, "must belong to the link's company") if employee && employee.company_id != company_id
  end
end
