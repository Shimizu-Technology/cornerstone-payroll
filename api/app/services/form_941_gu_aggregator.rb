# frozen_string_literal: true

# Form941GuAggregator
#
# Generates quarterly 941-GU style summary data from committed payroll items
# for a given company, year, and quarter.
#
# The Guam Form 941-GU mirrors the federal Form 941 and is filed with the
# Guam Department of Revenue and Taxation (DoRT). This aggregator produces
# structured data suitable for UI display and CSV/JSON export.
#
# === 941-GU Line Reference ===
# Line 1  – Number of employees who received wages in the quarter
# Line 2  – Total wages, tips, and other compensation (gross pay)
# Line 3  – Total Guam income tax withheld (withholding_tax)
# Line 5a – Taxable social security wages × 12.4% (employee 6.2% + employer 6.2%)
# Line 5b – Taxable social security tips × 12.4%  [placeholder – tips tracked separately]
# Line 5c – Taxable Medicare wages × 2.9% (employee 1.45% + employer 1.45%)
# Line 5d – Additional Medicare Tax wages (wages over $200K threshold per employee)
# Line 5e – Total SS + Medicare taxes (5a + 5b + 5c + 5d)
# Line 6  – Total taxes before adjustments (line 3 + line 5e)
# Line 7  – Adjustment: fractions of cents             [PLACEHOLDER]
# Line 8  – Adjustment: sick pay                        [PLACEHOLDER]
# Line 9  – Adjustment: tips / group-term life          [PLACEHOLDER]
# Line 10 – Total taxes after adjustments (line 6 + 7 + 8 + 9)
# Line 12 – Total taxes after credits (same as 10 absent credits)  [PLACEHOLDER for credits]
# Line 13 – Total deposits made this quarter             [PLACEHOLDER]
# Line 14 – Balance due / overpayment                   [PLACEHOLDER]
#
# NOTES / CAVEATS:
# - Adjustments (lines 7-9) and credits/deposits (11-14) are marked [PLACEHOLDER]
#   because they require data not currently stored in payroll_items.
# - Additional Medicare Tax (line 5d) is estimated from per-employee YTD gross
#   using the $200K threshold; this may differ from actual IRS/GRT computation
#   if employees changed employers mid-year.
# - Tips on line 5b are sourced from `reported_tips` on payroll_items.
# - Only "committed" pay periods are included (pay_date falls in the quarter).

class Form941GuAggregator
  SS_RATE_COMBINED      = 0.124  # 6.2% employee + 6.2% employer
  MEDICARE_RATE_COMBINED = 0.029 # 1.45% employee + 1.45% employer
  ADD_MEDICARE_RATE     = 0.009  # Additional Medicare Tax (employee only)
  ADD_MEDICARE_THRESHOLD = 200_000.00

  attr_reader :company, :year, :quarter

  # @param company [Company]
  # @param year    [Integer]
  # @param quarter [Integer] 1–4
  def initialize(company, year, quarter)
    @company = company
    @year    = year.to_i
    @quarter = quarter.to_i
    raise ArgumentError, "quarter must be 1–4" unless (1..4).cover?(@quarter)
  end

  # Returns the full 941-GU structured report hash.
  def generate
    items = qualifying_payroll_items

    # --- Line 2 breakdowns ---
    total_gross          = sum(items, :gross_pay)
    total_reported_tips  = sum(items, :reported_tips)
    # Line 2 is wages + tips + other compensation.
    line2_total_compensation = (total_gross + total_reported_tips).round(2)

    # --- Line 3 ---
    total_fit_withheld   = sum(items, :withholding_tax)

    # --- Line 5a: taxable SS wages derived from correctly-computed SS taxes ---
    ss_employee_total    = sum(items, :social_security_tax)
    ss_employer_total    = sum(items, :employer_social_security_tax)
    ss_combined_total    = ss_employee_total + ss_employer_total
    taxable_ss_wages     = (ss_combined_total / SS_RATE_COMBINED).round(2)

    # --- Line 5b: SS tips ---
    taxable_ss_tips      = sum(items, :reported_tips)
    ss_tips_combined     = (taxable_ss_tips * SS_RATE_COMBINED).round(2)

    # --- Line 5c: Medicare wages derived from computed Medicare tax totals ---
    medicare_employee_total = sum(items, :medicare_tax)
    medicare_employer_total = sum(items, :employer_medicare_tax)
    medicare_combined_total = medicare_employee_total + medicare_employer_total
    taxable_medicare_wages  = (medicare_combined_total / MEDICARE_RATE_COMBINED).round(2)

    # --- Line 5d: Additional Medicare Tax ---
    # Estimated per-employee: wages above $200K threshold within the quarter
    add_medicare_wages   = additional_medicare_taxable_wages(items)
    add_medicare_tax     = (add_medicare_wages * ADD_MEDICARE_RATE).round(2)

    # --- Line 5e totals ---
    line5e = (ss_combined_total + ss_tips_combined + medicare_combined_total + add_medicare_tax).round(2)

    # --- Line 6 ---
    line6  = (total_fit_withheld + line5e).round(2)

    # --- Adjustments (PLACEHOLDER) ---
    adj_fractions_of_cents = nil  # PLACEHOLDER: requires manual entry
    adj_sick_pay           = nil  # PLACEHOLDER: not tracked in payroll_items
    adj_tips_group_life    = nil  # PLACEHOLDER: not tracked in payroll_items

    # --- Line 10 ---
    line10 = line6  # Adjustments default to 0 when nil (not yet entered)

    # --- Employee breakdown for per-period schedule ---
    employee_count    = items.select("DISTINCT employee_id").count

    {
      meta: {
        report_type:    "form_941_gu",
        company_id:     company.id,
        company_name:   company.name,
        ein:            company.ein,
        year:           year,
        quarter:        quarter,
        quarter_label:  "Q#{quarter} #{year}",
        quarter_start:  quarter_start_date.iso8601,
        quarter_end:    quarter_end_date.iso8601,
        generated_at:   Time.current.iso8601,
        pay_periods_included: pay_period_count,
        caveats: [
          "Lines 7–9 (adjustments) are PLACEHOLDER: enter manually before filing.",
          "Lines 11–14 (credits/deposits/balance) are PLACEHOLDER: verify with DoRT deposits.",
          "Line 5b (SS tips) uses reported_tips; verify tip pool allocation if applicable.",
          "Line 5d (Additional Medicare Tax) is estimated from quarterly wages; actual may differ.",
          "Only 'committed' pay periods with pay_date in the quarter are included."
        ]
      },
      employer_info: {
        name:    company.name,
        ein:     company.ein,
        address: company.full_address
      },
      lines: {
        line1_employee_count:              employee_count,
        line2_wages_tips_other:            line2_total_compensation.to_f,
        line3_fit_withheld:                total_fit_withheld.to_f,

        line5a_ss_wages:                   taxable_ss_wages.to_f,
        line5a_ss_combined_tax:            ss_combined_total.to_f,
        line5b_ss_tips:                    taxable_ss_tips.to_f,
        line5b_ss_tips_combined_tax:       ss_tips_combined.to_f,
        line5c_medicare_wages:             taxable_medicare_wages.to_f,
        line5c_medicare_combined_tax:      medicare_combined_total.to_f,
        line5d_add_medicare_wages:         add_medicare_wages.to_f,
        line5d_add_medicare_tax:           add_medicare_tax.to_f,
        line5e_total_ss_medicare:          line5e.to_f,

        line6_total_taxes_before_adj:      line6.to_f,
        line7_adj_fractions_cents:         adj_fractions_of_cents, # PLACEHOLDER (nil = not entered)
        line8_adj_sick_pay:                adj_sick_pay,           # PLACEHOLDER
        line9_adj_tips_group_life:         adj_tips_group_life,    # PLACEHOLDER
        line10_total_taxes_after_adj:      line10.to_f,
        line11_nonrefundable_credits:      nil,                    # PLACEHOLDER
        line12_total_after_credits:        line10.to_f,            # PLACEHOLDER: same as 10 absent credits
        line13_total_deposits:             nil,                    # PLACEHOLDER
        line14_balance_due_or_overpayment: nil                     # PLACEHOLDER
      },
      # Detailed split for employer tax return and bookkeeping
      tax_detail: {
        gross_wages:                  total_gross.to_f,
        reported_tips:                total_reported_tips.to_f,
        fit_withheld:                 total_fit_withheld.to_f,
        ss_employee:                  ss_employee_total.to_f,
        ss_employer:                  ss_employer_total.to_f,
        ss_combined:                  ss_combined_total.to_f,
        medicare_employee:            medicare_employee_total.to_f,
        medicare_employer:            medicare_employer_total.to_f,
        medicare_combined:            medicare_combined_total.to_f,
        additional_medicare_employee: add_medicare_tax.to_f,
        total_employee_taxes:         (total_fit_withheld + ss_employee_total + medicare_employee_total + add_medicare_tax).round(2).to_f,
        total_employer_taxes:         (ss_employer_total + medicare_employer_total).round(2).to_f
      },
      # Monthly liability breakdown (for Form 941-GU Schedule B equivalent)
      monthly_liability: monthly_liability_breakdown(items)
    }
  end

  private

  def quarter_start_date
    start_month = ((quarter - 1) * 3) + 1
    Date.new(year, start_month, 1)
  end

  def quarter_end_date
    end_month = quarter * 3
    Date.new(year, end_month, -1)
  end

  def committed_pay_periods
    @committed_pay_periods ||= PayPeriod.committed
                                        .where(company_id: company.id)
                                        .where(pay_date: quarter_start_date..quarter_end_date)
  end

  def pay_period_count
    committed_pay_periods.count
  end

  def qualifying_payroll_items
    PayrollItem.joins(:pay_period)
               .includes(:pay_period)
               .where(pay_periods: { id: committed_pay_periods.select(:id) })
  end

  def sum(items, column)
    if items.is_a?(ActiveRecord::Relation)
      items.sum(column) || 0
    else
      items.sum { |item| item.public_send(column).to_f }
    end
  end

  # Estimate Additional Medicare Tax wages per-employee.
  # Wages above $200K in the quarter (conservative: uses quarterly gross;
  # full-year YTD is more accurate but requires cross-quarter data).
  def additional_medicare_taxable_wages(items)
    employee_quarter_wages = items.group(:employee_id).sum(:gross_pay)
    employee_quarter_wages.values.sum do |wages|
      excess = wages - ADD_MEDICARE_THRESHOLD
      excess > 0 ? excess : 0
    end.round(2)
  end

  # Monthly breakdown: total tax liability per calendar month in the quarter.
  # Useful for determining whether the company is a monthly or semiweekly depositor.
  # Must reconcile to line 6 total (FIT + line 5e), including SS tips and Additional Medicare.
  def monthly_liability_breakdown(items)
    months = (1..3).map { |i| quarter_start_date >> (i - 1) }
    records = items.to_a
    month_map = records.group_by { |item| item.pay_period.pay_date.beginning_of_month.to_date }
    monthly_add_medicare_wages = additional_medicare_taxable_wages_by_month(records)

    months.map do |month_start|
      month_end = month_start.end_of_month
      month_items = month_map[month_start] || []
      month_fit     = sum(month_items, :withholding_tax)
      month_ss_emp  = sum(month_items, :social_security_tax)
      month_ss_er   = sum(month_items, :employer_social_security_tax)
      month_med_emp = sum(month_items, :medicare_tax)
      month_med_er  = sum(month_items, :employer_medicare_tax)

      month_ss_tips = (sum(month_items, :reported_tips) * SS_RATE_COMBINED).round(2)
      month_add_med = (monthly_add_medicare_wages[month_start] * ADD_MEDICARE_RATE).round(2)

      total = (month_fit + month_ss_emp + month_ss_er + month_med_emp + month_med_er + month_ss_tips + month_add_med).round(2)

      {
        month:        month_start.strftime("%B %Y"),
        month_start:  month_start.iso8601,
        month_end:    month_end.iso8601,
        fit_withheld: month_fit.to_f,
        ss_combined:  (month_ss_emp + month_ss_er).round(2).to_f,
        ss_tips_combined: month_ss_tips.to_f,
        medicare_combined: (month_med_emp + month_med_er).round(2).to_f,
        add_medicare_tax: month_add_med.to_f,
        total_liability: total.to_f
      }
    end
  end

  # Allocate Additional Medicare taxable wages into calendar months based on
  # when each employee crosses the $200K threshold within the quarter.
  def additional_medicare_taxable_wages_by_month(items)
    allocations = Hash.new(0.0)

    items.group_by(&:employee_id)
         .each_value do |employee_items|
      running_wages = 0.0

      employee_items.sort_by { |item| [ item.pay_period.pay_date, item.id ] }.each do |item|
        gross = item.gross_pay.to_f
        prev_excess = [ running_wages - ADD_MEDICARE_THRESHOLD, 0.0 ].max
        running_wages += gross
        new_excess = [ running_wages - ADD_MEDICARE_THRESHOLD, 0.0 ].max

        delta_excess = (new_excess - prev_excess).round(2)
        next unless delta_excess.positive?

        month_key = item.pay_period.pay_date.beginning_of_month.to_date
        allocations[month_key] += delta_excess
      end
    end

    allocations
  end
end
