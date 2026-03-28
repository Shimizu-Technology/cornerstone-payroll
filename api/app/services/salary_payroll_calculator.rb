# frozen_string_literal: true

# Calculator for salary employees
#
# Gross pay = base_salary + tips + bonus
# base_salary = salary_override (per-period) OR (annual pay_rate / periods per year)
#
# For variable-pay owners: set salary_override on the PayrollItem to the
# per-period amount. This avoids needing to convert to an annual equivalent.
#
# Non-taxable pass-through payments (allotments, reimbursements) go in
# non_taxable_pay — they're added to the check but not subject to any taxes.
#
class SalaryPayrollCalculator < PayrollCalculator
  PERIODS_PER_YEAR = {
    "biweekly" => 26,
    "weekly" => 52,
    "semimonthly" => 24,
    "monthly" => 12
  }.freeze

  def calculate
    calculate_gross_pay
    record_earnings_breakdown
    calculate_retirement
    calculate_roth_retirement

    pre_tax_ded = pre_tax_employee_deductions_total
    taxable_for_withholding = [
      payroll_item.gross_pay.to_f - payroll_item.retirement_payment.to_f - pre_tax_ded,
      0.0
    ].max

    calculate_employer_retirement_match
    calculate_taxes(withholding_gross: taxable_for_withholding)
    apply_employee_deductions
    calculate_totals
    calculate_net_pay
    update_ytd_on_item
  end

  private

  def calculate_gross_pay
    if payroll_item.salary_override.present? && payroll_item.salary_override > 0
      @base_pay = payroll_item.salary_override.to_f
    else
      periods = PERIODS_PER_YEAR[employee.pay_frequency] || 26
      @base_pay = payroll_item.pay_rate / periods.to_f
    end

    @tips_amount = payroll_item.reported_tips.to_f
    @bonus_amount = payroll_item.bonus.to_f

    payroll_item.gross_pay = (@base_pay + @tips_amount + @bonus_amount).round(2)
  end

  def record_earnings_breakdown
    payroll_item.payroll_item_earnings.clear

    build_earning("salary", "Salary", nil, nil, @base_pay) if @base_pay > 0
    build_earning("tips", "Tips", nil, nil, @tips_amount) if @tips_amount > 0
    build_earning("bonus", "Bonus", nil, nil, @bonus_amount) if @bonus_amount > 0

    nontax = payroll_item.non_taxable_pay.to_f
    if nontax > 0
      build_earning("non_taxable", "Non-Taxable Pay", nil, nil, nontax)
    end
  end

  def build_earning(category, label, hours, rate, amount)
    payroll_item.payroll_item_earnings.build(
      category: category,
      label: label,
      hours: hours,
      rate: rate,
      amount: amount.to_f.round(2)
    )
  end
end
