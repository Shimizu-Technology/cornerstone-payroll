# frozen_string_literal: true

# An append-only record that a standalone software check represents the same
# physical payment as a committed payroll item. It does not void the check.
class NonEmployeeCheckSupersession < ApplicationRecord
  belongs_to :non_employee_check
  belongs_to :payroll_item
  belongs_to :user

  validates :reason, presence: true, length: { minimum: 20 }
  validate :same_company

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def same_company
    return if non_employee_check.blank? || payroll_item.blank?
    return if non_employee_check.company_id == payroll_item.company_id &&
              user&.organization_id == non_employee_check.company.organization_id

    errors.add(:base, "The duplicate check, payroll item, and reviewer must belong to the same company")
  end

  def prevent_mutation
    errors.add(:base, "Supersession evidence is append-only")
    throw :abort
  end
end
