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
  # A reversal can leave a signed balance when later negative corrections remain.
  # Preserve that ledger contribution so a subsequent correction reconciles exactly.
  def subtract_payroll_item!(payroll_item)
    with_lock do
      self.gross_pay          = gross_pay.to_d - payroll_item.gross_pay.to_d
      self.net_pay            = net_pay.to_d - payroll_item.net_pay.to_d
      self.withholding_tax    = withholding_tax.to_d - payroll_item.withholding_tax.to_d
      self.social_security_tax = social_security_tax.to_d - payroll_item.social_security_tax.to_d
      self.medicare_tax       = medicare_tax.to_d - payroll_item.medicare_tax.to_d
      remaining_retirement = retirement_totals_excluding(payroll_item)
      self.retirement         = remaining_retirement[:retirement].to_d
      self.roth_retirement    = remaining_retirement[:roth_retirement].to_d
      self.insurance          = insurance.to_d - payroll_item.insurance_payment.to_d
      self.loans              = loans.to_d - payroll_item.loan_payment.to_d
      self.tips_paid_out      = tips_paid_out.to_d - payroll_item.tips_paid_out.to_d
      self.tips               = tips.to_d - payroll_item.reported_tips.to_d
      self.bonus              = bonus.to_d - payroll_item.bonus.to_d
      self.overtime_pay       = overtime_pay.to_d - payroll_item.overtime_pay.to_d
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
