# frozen_string_literal: true

# Calculator for 1099 contractors
#
# Contractors receive gross pay with NO tax withholding:
# - No Federal/Guam income tax withholding
# - No Social Security (employee or employer)
# - No Medicare (employee or employer)
# - No retirement contributions
# - No employee deductions (loans, insurance, etc.)
#
# Gross pay can be:
# - Flat fee (salary_override on PayrollItem)
# - Hourly (hours_worked × pay_rate)
# - Fixed per-period (pay_rate used as flat amount when no hours)
#
class ContractorPayrollCalculator < PayrollCalculator
  def calculate
    calculate_gross_pay
    record_earnings_breakdown
    clear_deduction_state
    zero_out_taxes
    calculate_totals
    calculate_net_pay
    update_ytd_on_item
  end

  private

  def calculate_gross_pay
    if payroll_item.salary_override.present? && payroll_item.salary_override > 0
      @base_pay = payroll_item.salary_override.to_f
    elsif employee.contractor_hourly?
      if payroll_item.wage_rate_hours.present?
        calculate_multi_rate_gross_pay
      else
        rate = BigDecimal(payroll_item.pay_rate.to_s)
        @base_pay = (BigDecimal(payroll_item.hours_worked.to_s) * rate).to_f
        @overtime_pay = (BigDecimal(payroll_item.overtime_hours.to_s) * rate * BigDecimal("1.5")).to_f
        @holiday_pay = 0.0
        @pto_pay = 0.0
        @multi_rate_entries = nil
      end
    else
      @base_pay = payroll_item.pay_rate.to_f
    end

    @overtime_pay ||= 0.0
    @holiday_pay ||= 0.0
    @pto_pay ||= 0.0
    @bonus_amount = payroll_item.bonus.to_f

    payroll_item.gross_pay = (@base_pay + @overtime_pay + @holiday_pay + @pto_pay + @bonus_amount).round(2)
  end

  def record_earnings_breakdown
    payroll_item.payroll_item_earnings.clear

    if employee.contractor_hourly?
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
        build_earning("regular", "Contract Labor", payroll_item.hours_worked, payroll_item.pay_rate, @base_pay)
        if @overtime_pay > 0
          build_earning("overtime", "Contract OT", payroll_item.overtime_hours, payroll_item.pay_rate.to_f * 1.5, @overtime_pay)
        end
      end
    else
      build_earning("contract_fee", "Contract Fee", nil, nil, @base_pay) if @base_pay > 0
    end

    build_earning("bonus", "Bonus", nil, nil, @bonus_amount) if @bonus_amount > 0

    nontax = payroll_item.non_taxable_pay.to_f
    build_earning("non_taxable", "Non-Taxable Pay", nil, nil, nontax) if nontax > 0
  end

  def zero_out_taxes
    payroll_item.withholding_tax = 0
    payroll_item.social_security_tax = 0
    payroll_item.medicare_tax = 0
    payroll_item.additional_withholding = 0
    payroll_item.employer_social_security_tax = 0
    payroll_item.employer_medicare_tax = 0
    payroll_item.retirement_payment = 0
    payroll_item.roth_retirement_payment = 0
    payroll_item.employer_retirement_match = 0
    payroll_item.employer_roth_retirement_match = 0
  end

  def clear_deduction_state
    payroll_item.payroll_item_deductions.clear
    payroll_item.loan_payment = 0
    payroll_item.insurance_payment = 0
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

    @base_pay = @multi_rate_entries.sum { |entry| entry[:regular_pay] }
    @overtime_pay = @multi_rate_entries.sum { |entry| entry[:overtime_pay] }
    @holiday_pay = @multi_rate_entries.sum { |entry| entry[:holiday_pay] }
    @pto_pay = @multi_rate_entries.sum { |entry| entry[:pto_pay] }
  end
end
