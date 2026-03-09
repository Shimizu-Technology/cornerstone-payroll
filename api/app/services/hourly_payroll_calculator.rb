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
    # Use BigDecimal for precise money calculations
    rate = BigDecimal(payroll_item.pay_rate.to_s)
    
    regular_pay = BigDecimal(payroll_item.hours_worked.to_s) * rate
    overtime_pay = BigDecimal(payroll_item.overtime_hours.to_s) * rate * BigDecimal('1.5')
    holiday_pay = BigDecimal(payroll_item.holiday_hours.to_s) * rate
    pto_pay = BigDecimal(payroll_item.pto_hours.to_s) * rate

    # Tips are taxable income — include in gross pay before tax calculation
    tips = BigDecimal(payroll_item.reported_tips.to_s) + BigDecimal(payroll_item.tips.to_s)

    # Gross pay includes all pay plus tips and bonus
    total = regular_pay + overtime_pay + holiday_pay + pto_pay + tips + BigDecimal(payroll_item.bonus.to_s)
    payroll_item.gross_pay = total.round(2)
  end
end
