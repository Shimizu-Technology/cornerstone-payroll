# frozen_string_literal: true

# How a Cornerstone Tax user counts in Payroll: as one employee of the
# practice company (their pay is the cost), or as someone not on payroll
# (their hours carry no cost, e.g. an owner paid by draw).
class WorkHourStaffLink < ApplicationRecord
  DISPOSITIONS = %w[employee no_payroll].freeze

  belongs_to :organization
  belongs_to :employee, optional: true
  belongs_to :linked_by, class_name: "User", optional: true

  validates :tax_user_id, presence: true, uniqueness: { scope: :organization_id }
  validates :disposition, inclusion: { in: DISPOSITIONS }
  validate :employee_matches_disposition

  private

  def employee_matches_disposition
    if disposition == "employee"
      errors.add(:employee, "must be chosen") if employee.nil?
      errors.add(:employee, "must belong to this organization") if employee && employee.company&.organization_id != organization_id
    elsif employee_id.present?
      errors.add(:employee, "must be empty for someone not on payroll")
    end
  end
end
