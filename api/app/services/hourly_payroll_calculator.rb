# frozen_string_literal: true

# Calculator for hourly employees
#
# Gross pay = (regular hours × rate) + (overtime hours × rate × 1.5) + tips + bonus
#
class HourlyPayrollCalculator < PayrollCalculator
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
    regular_pay = payroll_item.hours_worked.to_f * payroll_item.pay_rate
    overtime_pay = payroll_item.overtime_hours.to_f * payroll_item.pay_rate * 1.5
    holiday_pay = payroll_item.holiday_hours.to_f * payroll_item.pay_rate
    pto_pay = payroll_item.pto_hours.to_f * payroll_item.pay_rate

    # Gross pay includes all pay plus tips and bonus
    payroll_item.gross_pay = (
      regular_pay +
      overtime_pay +
      holiday_pay +
      pto_pay +
      payroll_item.reported_tips.to_f +
      payroll_item.bonus.to_f
    ).round(2)
  end
end
