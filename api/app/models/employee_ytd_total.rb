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
      tips_paid_out: 0,
      tips: 0,
      bonus: 0,
      overtime_pay: 0
    )
  end

  # Update totals from a payroll item
  def add_payroll_item!(payroll_item)
    with_lock do
      retirement_totals = PayrollRetirementTotals.for_item(payroll_item)
      self.gross_pay += payroll_item.gross_pay.to_f
      self.net_pay += payroll_item.net_pay.to_f
      self.withholding_tax += payroll_item.withholding_tax.to_f
      self.social_security_tax += payroll_item.social_security_tax.to_f
      self.medicare_tax += payroll_item.medicare_tax.to_f
      prior_retirement = retirement_totals_excluding(payroll_item)
      self.retirement = prior_retirement[:retirement] + retirement_totals[:retirement]
      self.roth_retirement = prior_retirement[:roth_retirement] + retirement_totals[:roth_retirement]
      self.insurance += payroll_item.insurance_payment.to_f
      self.loans += payroll_item.loan_payment.to_f
      self.tips_paid_out += payroll_item.tips_paid_out.to_f
      self.tips += payroll_item.reported_tips.to_f
      self.bonus += payroll_item.bonus.to_f
      self.overtime_pay += payroll_item.overtime_pay.to_f
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
      remaining_retirement = retirement_totals_excluding(payroll_item)
      self.retirement         = [ remaining_retirement[:retirement], 0 ].max
      self.roth_retirement    = [ remaining_retirement[:roth_retirement], 0 ].max
      self.insurance          = [ insurance - payroll_item.insurance_payment.to_f, 0 ].max
      self.loans              = [ loans - payroll_item.loan_payment.to_f, 0 ].max
      self.tips_paid_out      = [ tips_paid_out - payroll_item.tips_paid_out.to_f, 0 ].max
      self.tips               = [ tips - payroll_item.reported_tips.to_f, 0 ].max
      self.bonus              = [ bonus - payroll_item.bonus.to_f, 0 ].max
      self.overtime_pay       = [ overtime_pay - payroll_item.overtime_pay.to_f, 0 ].max
      save!
    end
  end

  private

  # Older ledgers omitted fixed/flexible contributions. Rebuild only these
  # derived fields during a financial write so voiding an older paycheck cannot
  # consume contributions from a newer paycheck. Saved paychecks stay unchanged.
  def retirement_totals_excluding(payroll_item)
    committed_periods = PayPeriod.reportable_committed.where(
      company_id: employee.company_id,
      pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31)
    )
    scope = employee.payroll_items.not_voided.where(pay_period_id: committed_periods.select(:id))
                    .where.not(id: payroll_item.id)
    employee.merge_historical_ytd(PayrollRetirementTotals.for_scope(scope), year)
  end
end
