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

  def portal_enabled?
    company.active? && company.organization.active? && CompanyFeatures.for(company).employee_portal_enabled?
  end

  private

  def employee_belongs_to_live_company
    errors.add(:company, "must run live payroll") if company && !company.live_payroll?
    errors.add(:employee, "must belong to the link's company") if employee && employee.company_id != company_id
  end
end
