# frozen_string_literal: true

class PayrollLiabilityCheckAllocation < ApplicationRecord
  belongs_to :company
  belongs_to :non_employee_check, inverse_of: :payroll_liability_check_allocations
  belongs_to :payroll_liability_entry, inverse_of: :payroll_liability_check_allocations

  validates :amount, numericality: { greater_than: 0 }
  validates :payroll_liability_entry_id, uniqueness: { scope: :non_employee_check_id }
  validate :company_context_matches

  def readonly?
    persisted?
  end

  private

  def company_context_matches
    return if company.blank?

    if non_employee_check.present? && non_employee_check.company_id != company_id
      errors.add(:non_employee_check, "must belong to the allocation company")
    end
    if payroll_liability_entry.present? && payroll_liability_entry.company_id != company_id
      errors.add(:payroll_liability_entry, "must belong to the allocation company")
    end
  end
end
