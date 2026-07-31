# frozen_string_literal: true

# Form941GuAggregator
#
# Generates quarterly federal Form 941 worksheet data from committed payroll
# items for a given Guam company, year, and quarter.
#
# Current IRS Form 941 instructions say employers in Guam skip lines 2 and 3
# unless they have employees subject to U.S. income tax withholding. Guam wage
# withholding belongs in the Form 500/W-1 track, not on Form 941.
#
# === Federal Form 941 Line Reference ===
# Line 1  – Number of employees who received wages in the quarter
# Line 2  – Skipped for Guam employers by default
# Line 3  – Skipped for Guam employers by default
# Line 5a – Taxable social security wages × 12.4% (employee 6.2% + employer 6.2%)
# Line 5b – Taxable social security tips × 12.4%  [placeholder – tips tracked separately]
# Line 5c – Taxable Medicare wages × 2.9% (employee 1.45% + employer 1.45%)
# Line 5d – Additional Medicare Tax wages (wages over $200K threshold per employee)
# Line 5e – Total SS + Medicare taxes (5a + 5b + 5c + 5d)
# Line 6  – Total taxes before adjustments (line 5e; line 3 skipped)
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
# - Additional Medicare Tax (line 5d) uses stored Medicare taxable wage bases
#   when available; legacy rows use a compatibility reconstruction.
# - Tips on line 5b are sourced from `reported_tips` on payroll_items.
# - Only "committed" pay periods are included (pay_date falls in the quarter).

class Form941GuAggregator
  SS_RATE_COMBINED      = 0.124  # 6.2% employee + 6.2% employer
  MEDICARE_RATE_COMBINED = 0.029 # 1.45% employee + 1.45% employer
  ADD_MEDICARE_RATE      = 0.009  # Additional Medicare Tax (employee only)
  ADD_MEDICARE_THRESHOLD = 200_000.00
  FRACTIONS_OF_CENTS_WARNING_THRESHOLD = 0.10
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

  # Returns the full federal Form 941 structured report hash.
  def generate
    # Validate the filing-year rule set even when the quarter has no payroll.
    # An empty report for an unknown year must not look filing-ready.
    ss_wage_base

    items = qualifying_payroll_items
    records = items.to_a

    # --- Payroll detail retained for Guam W-1/SWICA tie-out context ---
    total_gross          = sum(records, :gross_pay)
    total_reported_tips  = sum(records, :reported_tips)

    # --- Form 941 lines 2 and 3 ---
    # Guam employers skip these by default unless they have employees subject
    # to U.S. federal income tax withholding. Guam withholding is tracked in
    # the Form 500/W-1 workflow.
    line2_total_compensation = nil
    line3_fit_withheld = nil
    guam_withholding_total = total_income_tax_withheld(records)

    # --- Line 5a / 5b: split SS wages and tips using actual wage-base ordering ---
    prior_ss_taxable_wages = prior_ss_taxable_wages_by_employee
    monthly_ss_allocations = ss_taxable_allocations_by_month(records, prior_ss_taxable_wages)
    taxable_ss_wages     = monthly_ss_allocations.values.sum { |allocation| allocation[:wages] }.round(2)
    taxable_ss_tips      = monthly_ss_allocations.values.sum { |allocation| allocation[:tips] }.round(2)
    ss_combined_total    = (taxable_ss_wages * ss_rate_combined).round(2)
    ss_tips_combined     = (taxable_ss_tips * ss_rate_combined).round(2)

    # --- Line 5c: Medicare wages and tips (base 2.9%) ---
    taxable_medicare_wages  = sum_taxable_base(records, :medicare_taxable_wages, fallback: :gross_pay)
    medicare_combined_total = (taxable_medicare_wages * medicare_rate_combined).round(2)

    # --- Actual tax totals retained for detail / reconciliation ---
    ss_employee_total       = sum(records, :social_security_tax)
    ss_employer_total       = sum(records, :employer_social_security_tax)
    medicare_employee_total = sum(records, :medicare_tax)
    medicare_employer_total = sum(records, :employer_medicare_tax)

    # --- Line 5d: Additional Medicare Tax ---
    prior_medicare_wages = prior_medicare_wages_by_employee
    monthly_add_medicare_wages = additional_medicare_taxable_wages_by_month(records, prior_medicare_wages)
    add_medicare_wages   = monthly_add_medicare_wages.values.sum.round(2)
    add_medicare_tax     = (add_medicare_wages * additional_medicare_rate).round(2)

    # --- Line 5e totals ---
    line5e = (ss_combined_total + ss_tips_combined + medicare_combined_total + add_medicare_tax).round(2)

    # --- Line 6 ---
    line6  = line5e.round(2)

    # Monthly liability breakdown (for Form 941 Part 2 / Schedule B support)
    monthly_liability = monthly_liability_breakdown(records, monthly_add_medicare_wages, monthly_ss_allocations)
    monthly_total_liability = monthly_liability.sum { |month| month[:total_liability].to_f }.round(2)

    # --- Adjustments ---
    adj_fractions_of_cents = fractions_of_cents_adjustment(
      line6: line6,
      monthly_total_liability: monthly_total_liability
    )
    adj_sick_pay           = nil  # PLACEHOLDER: not tracked in payroll_items
    adj_tips_group_life    = nil  # PLACEHOLDER: not tracked in payroll_items

    # --- Line 10 ---
    line10 = (line6 + adj_fractions_of_cents.to_f).round(2)

    # --- Employee breakdown for per-period schedule ---
    employee_count    = line1_employee_count

    {
      meta: {
        report_type:    "federal_form_941",
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
          "Line 7 auto-computes fractions-of-cents adjustment when monthly liability rounding differs from quarter totals.",
          "Line 7 fractions-of-cents uses (monthly Schedule B total - line 6); positive means monthly liability exceeds line 6, negative means it is lower.",
          "Lines 8–9 (adjustments) are PLACEHOLDER: enter manually before filing.",
          "Lines 2 and 3 are skipped by default for Guam employers unless employees are subject to U.S. federal income tax withholding.",
          "Guam wage withholding is tracked through Form 500/W-1 and surfaced in tax_detail.guam_withholding_for_w1.",
          "Lines 11–14 (credits/deposits/balance) are PLACEHOLDER: verify with federal deposit records.",
          "Line 5b (SS tips) is derived from reported tips remaining under the SS wage base.",
          "Committed taxable wage bases are used when present; legacy payroll rows without stored bases use compatibility reconstruction and must be reviewed.",
          "tax_detail.ss_combined includes Social Security tax on both SS wages and SS-taxable tips; reconcile to lines 5a + 5b rather than line 5a alone.",
          "tax_detail.ss_combined is based on stored SS taxes, so it can differ from lines 5a + 5b by a few cents due to rounding.",
          "Line 5d (Additional Medicare Tax) is estimated from year-to-date Medicare wages; verify against prior-quarter history.",
          "If prior-quarter payroll was committed before tips were embedded in gross_pay, verify transition-year Additional Medicare carry-forward manually.",
          "Only 'committed' pay periods with pay_date in the quarter are included."
        ]
      },
      filing_readiness: {
        status: "draft",
        ready_to_file: false,
        message: "Preparation copy only. Complete and verify adjustments, credits, deposits, balance due or overpayment, and signer/preparer fields before filing.",
        blockers: [
          "Lines 8–9 adjustments require manual review.",
          "Lines 11–14 credits, deposits, and balance require federal deposit records.",
          "Signer and paid-preparer sections are not completed by Cornerstone."
        ]
      },
      employer_info: {
        name:    company.name,
        ein:     company.ein,
        address: company.full_address
      },
      lines: {
        line1_employee_count:              employee_count,
        line2_wages_tips_other:            line2_total_compensation,
        line3_fit_withheld:                line3_fit_withheld,

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
        line7_adj_fractions_cents:         adj_fractions_of_cents&.to_f,
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
        fit_withheld:                 nil,
        ss_employee:                  ss_employee_total.to_f,
        ss_employer:                  ss_employer_total.to_f,
        ss_wages_combined:            ss_combined_total.to_f,
        ss_tips_combined:             ss_tips_combined.to_f,
        ss_combined:                  (ss_employee_total + ss_employer_total).round(2).to_f,
        medicare_employee:            medicare_employee_total.to_f,
        medicare_employer:            medicare_employer_total.to_f,
        medicare_combined:            medicare_combined_total.to_f,
        additional_medicare_employee: add_medicare_tax.to_f,
        guam_withholding_for_w1:      guam_withholding_total.to_f,
        total_employee_taxes:         (ss_employee_total + medicare_employee_total).round(2).to_f,
        total_employer_taxes:         (ss_employer_total + medicare_employer_total).round(2).to_f
      },
      monthly_liability: monthly_liability
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
               .where(company_id: company.id)
               .where(pay_period_id: committed_pay_periods.select(:id))
               .not_voided
               .where.not(employment_type: "contractor")
  end

  def sum(items, column)
    if items.is_a?(ActiveRecord::Relation)
      items.sum(column) || 0
    else
      items.sum { |item| item.public_send(column).to_f }
    end
  end

  def total_income_tax_withheld(items)
    items.sum { |item| item.total_income_tax_withheld }.round(2)
  end

  def sum_taxable_base(items, column, fallback:)
    items.sum do |item|
      stored = item.public_send(column)
      (stored.nil? ? item.public_send(fallback) : stored).to_d
    end.round(2)
  end

  def fractions_of_cents_adjustment(line6:, monthly_total_liability:)
    diff = (monthly_total_liability - line6).round(2)
    return nil if diff.zero?

    if diff.abs > FRACTIONS_OF_CENTS_WARNING_THRESHOLD
      Rails.logger.warn(
        "[Form941GuAggregator] Large fractions-of-cents adjustment=#{diff} " \
        "(company=#{company.id}, year=#{year}, quarter=#{quarter}). Verify monthly liability breakdown."
      )
    end

    diff
  end

  # Monthly breakdown: total tax liability per calendar month in the quarter.
  # Useful for determining whether the company is a monthly or semiweekly depositor.
  # Must reconcile to line 6 total (line 5e for Guam employers), including SS
  # tips and Additional Medicare.
  def monthly_liability_breakdown(records, monthly_add_medicare_wages, monthly_ss_allocations)
    months = (1..3).map { |i| quarter_start_date >> (i - 1) }
    month_map = records.group_by { |item| item.pay_period.pay_date.beginning_of_month.to_date }

    months.map do |month_start|
      month_end = month_start.end_of_month
      month_items = month_map[month_start] || []
      month_guam_withholding = total_income_tax_withheld(month_items)
      month_medicare_wages   = sum_taxable_base(month_items, :medicare_taxable_wages, fallback: :gross_pay)
      month_ss_wages         = monthly_ss_allocations.fetch(month_start, { wages: 0.0, tips: 0.0 })[:wages]
      month_ss_tips          = monthly_ss_allocations.fetch(month_start, { wages: 0.0, tips: 0.0 })[:tips]
      month_ss_combined      = (month_ss_wages * ss_rate_combined).round(2)
      month_ss_tips_combined = (month_ss_tips * ss_rate_combined).round(2)
      month_medicare         = (month_medicare_wages * medicare_rate_combined).round(2)
      month_add_med          = (monthly_add_medicare_wages[month_start] * additional_medicare_rate).round(2)

      total = (month_ss_combined + month_ss_tips_combined + month_medicare + month_add_med).round(2)

      {
        month:        month_start.strftime("%B %Y"),
        month_start:  month_start.iso8601,
        month_end:    month_end.iso8601,
        fit_withheld: nil,
        guam_withholding_for_w1: month_guam_withholding.to_f,
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
        if item.social_security_taxable_wages.present? && item.social_security_taxable_tips.present?
          taxable_wages = item.social_security_taxable_wages.to_d
          taxable_tips = item.social_security_taxable_tips.to_d
          allocations[month_key][:wages] += taxable_wages
          allocations[month_key][:tips] += taxable_tips
          running_taxable_wages += taxable_wages + taxable_tips
          next
        end

        if item.reported_tips.to_f > item.gross_pay.to_f
          Rails.logger.warn(
            "[Form941GuAggregator] payroll_item=#{item.id} reported_tips exceed gross_pay; " \
            "clamping wages_only to zero for SS allocation"
          )
        end
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
        month_key = item.pay_period.pay_date.beginning_of_month.to_date
        if item.additional_medicare_taxable_wages.present?
          allocations[month_key] += item.additional_medicare_taxable_wages.to_d
          running_wages += (item.medicare_taxable_wages || item.gross_pay).to_d
          next
        end

        medicare_wages = (item.medicare_taxable_wages || item.gross_pay).to_d
        prev_excess = [ running_wages - additional_medicare_threshold, 0.0 ].max
        running_wages += medicare_wages
        new_excess = [ running_wages - additional_medicare_threshold, 0.0 ].max

        delta_excess = (new_excess - prev_excess).round(2)
        next unless delta_excess.positive?

        allocations[month_key] += delta_excess
      end
    end

    allocations
  end

  # SS-taxable wages already consumed before this quarter, by employee.
  # Derived from posted SS taxes to preserve historical cap behavior across prior quarters.
  def prior_ss_taxable_wages_by_employee
    # Stored employee+employer SS taxes always reflect the total SS-taxable base
    # consumed in prior quarters, including SS-taxable tips when present. Dividing
    # that combined tax by the combined SS rate therefore reconstructs the same
    # wages+tips headroom consumption used by the current-quarter allocator.
    rate = PayrollItem.connection.quote(ss_rate_combined.to_d)
    aggregate = Arel.sql(<<~SQL.squish)
      ROUND(SUM(
        CASE
          WHEN social_security_taxable_wages IS NOT NULL
           AND social_security_taxable_tips IS NOT NULL
            THEN social_security_taxable_wages + social_security_taxable_tips
          ELSE (COALESCE(social_security_tax, 0) + COALESCE(employer_social_security_tax, 0)) / NULLIF(#{rate}, 0)
        END
      ), 2)
    SQL

    prior_payroll_items.group(:employee_id).pluck(:employee_id, aggregate).to_h
  end

  def prior_medicare_wages_by_employee
    # Prior-quarter Additional Medicare carry-forward relies on stored gross_pay.
    # For transition-year data committed before tips were embedded in gross_pay,
    # operators should verify year-to-date Medicare wages manually.
    aggregate = Arel.sql("ROUND(SUM(COALESCE(medicare_taxable_wages, gross_pay)), 2)")
    prior_payroll_items.group(:employee_id).pluck(:employee_id, aggregate).to_h
  end

  def prior_payroll_items
    PayrollItem.joins(:pay_period)
               .where(company_id: company.id)
               .not_voided
               .where.not(employment_type: "contractor")
               .where(pay_periods: {
                 id: PayPeriod.reportable_committed
                   .where(company_id: company.id, pay_date: Date.new(year, 1, 1)...quarter_start_date)
                   .select(:id)
               })
  end

  def line1_employee_count
    reference_date = Date.new(year, quarter * 3, 12)

    PayrollItem.joins(:pay_period)
               .where(company_id: company.id)
               .not_voided
               .where(pay_periods: {
                 id: PayPeriod.reportable_committed
                   .where(company_id: company.id)
                   .where("start_date <= ? AND end_date >= ?", reference_date, reference_date)
                   .where(end_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                   .select(:id)
               })
               .where.not(employment_type: "contractor")
               .distinct
               .count(:employee_id)
  end

  def ss_wage_base
    AnnualTaxConfig.for_year(year)&.ss_wage_base&.to_f || SS_WAGE_BASE_BY_YEAR.fetch(year) do
      raise ArgumentError, "SS wage base not configured for #{year}. Add #{year} to SS_WAGE_BASE_BY_YEAR."
    end
  end

  def annual_tax_config
    @annual_tax_config ||= AnnualTaxConfig.for_year(year)
  end

  def ss_rate_combined
    annual_tax_config ? annual_tax_config.ss_rate.to_f * 2 : SS_RATE_COMBINED
  end

  def medicare_rate_combined
    annual_tax_config ? annual_tax_config.medicare_rate.to_f * 2 : MEDICARE_RATE_COMBINED
  end

  def additional_medicare_rate
    annual_tax_config ? annual_tax_config.additional_medicare_rate.to_f : ADD_MEDICARE_RATE
  end

  def additional_medicare_threshold
    annual_tax_config ? annual_tax_config.additional_medicare_threshold.to_f : ADD_MEDICARE_THRESHOLD
  end
end
