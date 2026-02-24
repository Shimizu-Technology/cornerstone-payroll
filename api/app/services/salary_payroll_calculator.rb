# frozen_string_literal: true

# Calculator for salary employees
#
# Gross pay = (annual salary / periods per year) + tips + bonus
#
# For salary employees:
# - pay_rate is the ANNUAL salary
# - Divided by pay periods per year (26 for biweekly)
#
class SalaryPayrollCalculator < PayrollCalculator
  # Periods per year by pay frequency
  PERIODS_PER_YEAR = {
    "biweekly" => 26,
    "weekly" => 52,
    "semimonthly" => 24,
    "monthly" => 12
  }.freeze

  def calculate
    calculate_gross_pay
    calculate_retirement        # Pre-tax
    calculate_roth_retirement   # Post-tax (but calculated on gross)
    taxable_for_withholding = [ payroll_item.gross_pay.to_f - payroll_item.retirement_payment.to_f, 0.0 ].max
    calculate_taxes(withholding_gross: taxable_for_withholding) # Withholding, SS, Medicare
    calculate_totals
    calculate_net_pay
    update_ytd_on_item
  end

  private

  def calculate_gross_pay
    periods = PERIODS_PER_YEAR[employee.pay_frequency] || 26
    base_pay = payroll_item.pay_rate / periods.to_f

    # Salary employees can still have tips and bonuses
    payroll_item.gross_pay = (
      base_pay +
      payroll_item.reported_tips.to_f +
      payroll_item.bonus.to_f
    ).round(2)
  end
end
