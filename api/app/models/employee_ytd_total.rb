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

  # CPR-71: Reverse the YTD contribution of a payroll item (used when voiding a committed period).
  # Floors each field at 0 to guard against rounding edge-cases producing negative YTDs.
  def subtract_payroll_item!(payroll_item)
    with_lock do
      self.gross_pay          = [ gross_pay - payroll_item.gross_pay.to_f, 0 ].max
      self.net_pay            = [ net_pay - payroll_item.net_pay.to_f, 0 ].max
      self.withholding_tax    = [ withholding_tax - payroll_item.withholding_tax.to_f, 0 ].max
      self.social_security_tax = [ social_security_tax - payroll_item.social_security_tax.to_f, 0 ].max
      self.medicare_tax       = [ medicare_tax - payroll_item.medicare_tax.to_f, 0 ].max
      self.retirement         = [ retirement - payroll_item.retirement_payment.to_f, 0 ].max
      self.roth_retirement    = [ roth_retirement - payroll_item.roth_retirement_payment.to_f, 0 ].max
      self.insurance          = [ insurance - payroll_item.insurance_payment.to_f, 0 ].max
      self.loans              = [ loans - payroll_item.loan_payment.to_f, 0 ].max
      self.tips               = [ tips - payroll_item.reported_tips.to_f, 0 ].max
      self.bonus              = [ bonus - payroll_item.bonus.to_f, 0 ].max
      self.overtime_pay       = [ overtime_pay - (payroll_item.overtime_hours.to_f * payroll_item.pay_rate * 1.5), 0 ].max
      save!
    end
  end
end
