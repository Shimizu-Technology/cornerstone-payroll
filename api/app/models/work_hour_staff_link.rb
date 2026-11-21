# frozen_string_literal: true

# How a Cornerstone Tax user counts in Payroll: as one employee of the
# practice company (their pay is the cost), or as someone not on payroll
# (their hours carry no cost, e.g. an owner paid by draw).
class WorkHourStaffLink < ApplicationRecord
  DISPOSITIONS = %w[employee no_payroll].freeze

  belongs_to :organization
  belongs_to :employee, optional: true
  belongs_to :linked_by, class_name: "User", optional: true

  # Unlinking deactivates the row; relinking reactivates the same row.
  scope :active, -> { where(active: true) }

  validates :tax_user_id, presence: true, uniqueness: { scope: :organization_id }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validate :employee_matches_disposition

  private

  # An active employee link must point at the organization's current
  # practice company: only that company's payroll is costed.
  def employee_matches_disposition
    if disposition == "employee"
      if employee.nil?
        errors.add(:employee, "must be chosen")
      elsif active? && employee.company_id != ClientProfitabilitySetting.find_by(organization_id: organization_id)&.practice_company_id
        errors.add(:employee, "must work for the client that runs Cornerstone's own staff payroll")
      end
    elsif employee_id.present?
      errors.add(:employee, "must be empty for someone not on payroll")
    end
  end
end
