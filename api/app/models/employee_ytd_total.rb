# frozen_string_literal: true

class EmployeeYtdTotal < ApplicationRecord
  belongs_to :employee

  validates :year, presence: true
  validates :year, uniqueness: { scope: :employee_id }

  # Reset all totals to zero
  def reset!
    update!(
      gross_pay: 0,
      net_pay: 0,
      withholding_tax: 0,
      social_security_tax: 0,
      medicare_tax: 0,
      retirement: 0,
      roth_retirement: 0,
      insurance: 0,
      loans: 0,
      tips: 0,
      bonus: 0,
      overtime_pay: 0
    )
  end

  # Update totals from a payroll item
  def add_payroll_item!(payroll_item)
    with_lock do
      self.gross_pay += payroll_item.gross_pay.to_f
      self.net_pay += payroll_item.net_pay.to_f
      self.withholding_tax += payroll_item.withholding_tax.to_f
      self.social_security_tax += payroll_item.social_security_tax.to_f
      self.medicare_tax += payroll_item.medicare_tax.to_f
      self.retirement += payroll_item.retirement_payment.to_f
      self.roth_retirement += payroll_item.roth_retirement_payment.to_f
      self.insurance += payroll_item.insurance_payment.to_f
      self.loans += payroll_item.loan_payment.to_f
      self.tips += payroll_item.reported_tips.to_f
      self.bonus += payroll_item.bonus.to_f
      self.overtime_pay += (payroll_item.overtime_hours.to_f * payroll_item.pay_rate * 1.5)
      save!
    end
  end
end
