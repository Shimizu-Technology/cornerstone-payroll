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
  ADD_MEDICARE_RATE      = 0.009  # Additional Medicare Tax (employee only)
  ADD_MEDICARE_THRESHOLD = 200_000.00
  SS_WAGE_BASE_BY_YEAR = {
    2025 => 176_100.00,
    2026 => 184_500.00
  }.freeze

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
    # Fail fast for unsupported SS wage-base years.
    ss_wage_base

    items = qualifying_payroll_items
    records = items.to_a

    # --- Line 2 breakdowns ---
    total_gross          = sum(records, :gross_pay)
    total_reported_tips  = sum(records, :reported_tips)
    # `gross_pay` already includes reported tips in the payroll calculators.
    line2_total_compensation = total_gross.round(2)

    # --- Line 3 ---
    total_fit_withheld   = sum(records, :withholding_tax)

    # --- Line 5a / 5b: split SS wages and tips using actual wage-base ordering ---
    prior_ss_taxable_wages = prior_ss_taxable_wages_by_employee
    monthly_ss_allocations = ss_taxable_allocations_by_month(records, prior_ss_taxable_wages)
    taxable_ss_wages     = monthly_ss_allocations.values.sum { |allocation| allocation[:wages] }.round(2)
    taxable_ss_tips      = monthly_ss_allocations.values.sum { |allocation| allocation[:tips] }.round(2)
    ss_combined_total    = (taxable_ss_wages * SS_RATE_COMBINED).round(2)
    ss_tips_combined     = (taxable_ss_tips * SS_RATE_COMBINED).round(2)

    # --- Line 5c: Medicare wages and tips (base 2.9%) ---
    taxable_medicare_wages  = total_gross.round(2)
    medicare_combined_total = (taxable_medicare_wages * MEDICARE_RATE_COMBINED).round(2)

    # --- Actual tax totals retained for detail / reconciliation ---
    ss_employee_total       = sum(records, :social_security_tax)
    ss_employer_total       = sum(records, :employer_social_security_tax)
    medicare_employee_total = sum(records, :medicare_tax)
    medicare_employer_total = sum(records, :employer_medicare_tax)

    # --- Line 5d: Additional Medicare Tax ---
    prior_medicare_wages = prior_medicare_wages_by_employee
    monthly_add_medicare_wages = additional_medicare_taxable_wages_by_month(records, prior_medicare_wages)
    add_medicare_wages   = monthly_add_medicare_wages.values.sum.round(2)
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
    employee_count    = line1_employee_count

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
          "Line 5b (SS tips) is derived from reported tips remaining under the SS wage base.",
          "Line 5d (Additional Medicare Tax) is estimated from year-to-date Medicare wages; verify against prior-quarter history.",
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
        ss_combined:                  (ss_employee_total + ss_employer_total).round(2).to_f,
        medicare_employee:            medicare_employee_total.to_f,
        medicare_employer:            medicare_employer_total.to_f,
        medicare_combined:            medicare_combined_total.to_f,
        additional_medicare_employee: add_medicare_tax.to_f,
        total_employee_taxes:         (total_fit_withheld + ss_employee_total + medicare_employee_total + add_medicare_tax).round(2).to_f,
        total_employer_taxes:         (ss_employer_total + medicare_employer_total).round(2).to_f
      },
      # Monthly liability breakdown (for Form 941-GU Schedule B equivalent)
      monthly_liability: monthly_liability_breakdown(records, monthly_add_medicare_wages, monthly_ss_allocations)
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
    @committed_pay_periods ||= PayPeriod.reportable_committed
                                        .where(company_id: company.id)
                                        .where(pay_date: quarter_start_date..quarter_end_date)
  end

  def pay_period_count
    committed_pay_periods.count
  end

  def qualifying_payroll_items
    PayrollItem.includes(:pay_period)
               .where(pay_period_id: committed_pay_periods.select(:id))
  end

  def sum(items, column)
    if items.is_a?(ActiveRecord::Relation)
      items.sum(column) || 0
    else
      items.sum { |item| item.public_send(column).to_f }
    end
  end

  # Monthly breakdown: total tax liability per calendar month in the quarter.
  # Useful for determining whether the company is a monthly or semiweekly depositor.
  # Must reconcile to line 6 total (FIT + line 5e), including SS tips and Additional Medicare.
  def monthly_liability_breakdown(records, monthly_add_medicare_wages, monthly_ss_allocations)
    months = (1..3).map { |i| quarter_start_date >> (i - 1) }
    month_map = records.group_by { |item| item.pay_period.pay_date.beginning_of_month.to_date }

    months.map do |month_start|
      month_end = month_start.end_of_month
      month_items = month_map[month_start] || []
      month_fit              = sum(month_items, :withholding_tax)
      month_gross            = sum(month_items, :gross_pay)
      month_ss_wages         = monthly_ss_allocations.fetch(month_start, { wages: 0.0, tips: 0.0 })[:wages]
      month_ss_tips          = monthly_ss_allocations.fetch(month_start, { wages: 0.0, tips: 0.0 })[:tips]
      month_ss_combined      = (month_ss_wages * SS_RATE_COMBINED).round(2)
      month_ss_tips_combined = (month_ss_tips * SS_RATE_COMBINED).round(2)
      month_medicare         = (month_gross * MEDICARE_RATE_COMBINED).round(2)
      month_add_med          = (monthly_add_medicare_wages[month_start] * ADD_MEDICARE_RATE).round(2)

      total = (month_fit + month_ss_combined + month_ss_tips_combined + month_medicare + month_add_med).round(2)

      {
        month:        month_start.strftime("%B %Y"),
        month_start:  month_start.iso8601,
        month_end:    month_end.iso8601,
        fit_withheld: month_fit.to_f,
        ss_combined:  month_ss_combined.to_f,
        ss_tips_combined: month_ss_tips_combined.to_f,
        medicare_combined: month_medicare.to_f,
        add_medicare_tax: month_add_med.to_f,
        total_liability: total.to_f
      }
    end
  end

  # Allocate SS-taxable wages and tips into calendar months after applying the
  # per-employee SS wage base. Wages consume headroom before tips.
  def ss_taxable_allocations_by_month(items, prior_ss_taxable_wages = {})
    allocations = Hash.new { |hash, key| hash[key] = { wages: 0.0, tips: 0.0 } }

    items.group_by(&:employee_id)
         .each do |employee_id, employee_items|
      running_taxable_wages = prior_ss_taxable_wages[employee_id].to_f

      employee_items.sort_by { |item| [ item.pay_period.pay_date, item.id ] }.each do |item|
        month_key = item.pay_period.pay_date.beginning_of_month.to_date
        wages_only = [ item.gross_pay.to_f - item.reported_tips.to_f, 0.0 ].max
        remaining_headroom = [ ss_wage_base - running_taxable_wages, 0.0 ].max
        taxable_wages = [ wages_only, remaining_headroom ].min.round(2)
        remaining_headroom_after_wages = [ remaining_headroom - taxable_wages, 0.0 ].max
        taxable_tips = [ item.reported_tips.to_f, remaining_headroom_after_wages ].min.round(2)

        allocations[month_key][:wages] += taxable_wages if taxable_wages.positive?
        allocations[month_key][:tips] += taxable_tips if taxable_tips.positive?
        running_taxable_wages += taxable_wages + taxable_tips
      end
    end

    allocations
  end

  # Allocate Additional Medicare taxable wages into calendar months based on
  # when each employee crosses the $200K threshold within the quarter.
  def additional_medicare_taxable_wages_by_month(items, prior_medicare_wages = {})
    allocations = Hash.new(0.0)

    items.group_by(&:employee_id)
         .each do |employee_id, employee_items|
      running_wages = prior_medicare_wages[employee_id].to_f

      employee_items.sort_by { |item| [ item.pay_period.pay_date, item.id ] }.each do |item|
        # Additional Medicare threshold applies to Medicare wages, already reflected in gross_pay.
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

  # SS-taxable wages already consumed before this quarter, by employee.
  # Derived from posted SS taxes to preserve historical cap behavior across prior quarters.
  def prior_ss_taxable_wages_by_employee
    prior_items = PayrollItem.joins(:pay_period)
                             .where(pay_periods: {
                               id: PayPeriod.reportable_committed
                                 .where(company_id: company.id, pay_date: Date.new(year, 1, 1)...quarter_start_date)
                                 .select(:id)
                             })

    prior_items.group(:employee_id)
               .sum("social_security_tax + employer_social_security_tax")
               .transform_values { |combined_tax| (combined_tax.to_f / SS_RATE_COMBINED).round(2) }
  end

  def prior_medicare_wages_by_employee
    PayrollItem.joins(:pay_period)
               .where(pay_periods: {
                 id: PayPeriod.reportable_committed
                   .where(company_id: company.id, pay_date: Date.new(year, 1, 1)...quarter_start_date)
                   .select(:id)
               })
               .group(:employee_id)
               .sum(:gross_pay)
               .transform_values(&:to_f)
  end

  def line1_employee_count
    reference_date = Date.new(year, quarter * 3, 12)

    PayrollItem.joins(:pay_period)
               .where(pay_periods: {
                 id: PayPeriod.reportable_committed
                   .where(company_id: company.id)
                   .where("start_date <= ? AND end_date >= ?", reference_date, reference_date)
                   .select(:id)
               })
               .distinct
               .count(:employee_id)
  end

  def ss_wage_base
    SS_WAGE_BASE_BY_YEAR.fetch(year) do
      raise ArgumentError, "SS wage base not configured for #{year}. Add #{year} to SS_WAGE_BASE_BY_YEAR."
    end
  end
end
