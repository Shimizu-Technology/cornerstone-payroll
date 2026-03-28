# frozen_string_literal: true

# Calculator for hourly employees
#
# Gross pay = (regular hours × rate) + (overtime hours × rate × 1.5) + tips + bonus
#
class HourlyPayrollCalculator < PayrollCalculator
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
    if payroll_item.wage_rate_hours.present?
      calculate_multi_rate_gross_pay
    else
      calculate_single_rate_gross_pay
    end

    @tips_amount = BigDecimal(payroll_item.reported_tips.to_s)
    @bonus_amount = BigDecimal(payroll_item.bonus.to_s)

    total = @regular_pay + @overtime_pay + @holiday_pay + @pto_pay + @tips_amount + @bonus_amount
    payroll_item.gross_pay = total.round(2)
  end

  def record_earnings_breakdown
    payroll_item.payroll_item_earnings.clear

    if @multi_rate_entries.present?
      @multi_rate_entries.each do |entry|
        rate = entry[:rate].to_f
        label = entry[:label]

        build_earning("regular", label, entry[:regular_hours], rate, entry[:regular_pay]) if entry[:regular_pay] > 0
        build_earning("overtime", "#{label} OT", entry[:overtime_hours], rate * 1.5, entry[:overtime_pay]) if entry[:overtime_pay] > 0
        build_earning("holiday", "#{label} Holiday", entry[:holiday_hours], rate, entry[:holiday_pay]) if entry[:holiday_pay] > 0
        build_earning("pto", "#{label} PTO", entry[:pto_hours], rate, entry[:pto_pay]) if entry[:pto_pay] > 0
      end
    else
      rate = payroll_item.pay_rate.to_f

      build_earning("regular", "Regular Pay", payroll_item.hours_worked, rate, @regular_pay) if @regular_pay > 0
      build_earning("overtime", "Overtime Pay", payroll_item.overtime_hours, rate * 1.5, @overtime_pay) if @overtime_pay > 0
      build_earning("holiday", "Holiday Pay", payroll_item.holiday_hours, rate, @holiday_pay) if @holiday_pay > 0
      build_earning("pto", "PTO Pay", payroll_item.pto_hours, rate, @pto_pay) if @pto_pay > 0
    end

    build_earning("tips", "Tips", nil, nil, @tips_amount) if @tips_amount > 0
    build_earning("bonus", "Bonus", nil, nil, @bonus_amount) if @bonus_amount > 0
  end

  def calculate_single_rate_gross_pay
    rate = BigDecimal(payroll_item.pay_rate.to_s)

    @regular_pay = BigDecimal(payroll_item.hours_worked.to_s) * rate
    @overtime_pay = BigDecimal(payroll_item.overtime_hours.to_s) * rate * BigDecimal("1.5")
    @holiday_pay = BigDecimal(payroll_item.holiday_hours.to_s) * rate
    @pto_pay = BigDecimal(payroll_item.pto_hours.to_s) * rate
    @multi_rate_entries = nil
  end

  def calculate_multi_rate_gross_pay
    @multi_rate_entries = payroll_item.wage_rate_hours.map do |entry|
      rate = BigDecimal(entry["rate"].to_s)
      regular_hours = BigDecimal(entry["regular_hours"].to_s)
      overtime_hours = BigDecimal(entry["overtime_hours"].to_s)
      holiday_hours = BigDecimal(entry["holiday_hours"].to_s)
      pto_hours = BigDecimal(entry["pto_hours"].to_s)

      {
        label: entry["label"],
        rate: rate,
        regular_hours: regular_hours.to_f,
        overtime_hours: overtime_hours.to_f,
        holiday_hours: holiday_hours.to_f,
        pto_hours: pto_hours.to_f,
        regular_pay: regular_hours * rate,
        overtime_pay: overtime_hours * rate * BigDecimal("1.5"),
        holiday_pay: holiday_hours * rate,
        pto_pay: pto_hours * rate
      }
    end

    payroll_item.hours_worked = @multi_rate_entries.sum { |entry| entry[:regular_hours] }
    payroll_item.overtime_hours = @multi_rate_entries.sum { |entry| entry[:overtime_hours] }
    payroll_item.holiday_hours = @multi_rate_entries.sum { |entry| entry[:holiday_hours] }
    payroll_item.pto_hours = @multi_rate_entries.sum { |entry| entry[:pto_hours] }

    @regular_pay = @multi_rate_entries.sum { |entry| entry[:regular_pay] }
    @overtime_pay = @multi_rate_entries.sum { |entry| entry[:overtime_pay] }
    @holiday_pay = @multi_rate_entries.sum { |entry| entry[:holiday_pay] }
    @pto_pay = @multi_rate_entries.sum { |entry| entry[:pto_pay] }
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
