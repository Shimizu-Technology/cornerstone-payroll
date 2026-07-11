# frozen_string_literal: true

# Guam Tax Calculator
#
# Calculates Guam Territorial Income Tax (same as federal brackets),
# Social Security, and Medicare withholding.
#
# Key features:
# - Database-driven tax tables (no hardcoded brackets)
# - SS wage base cap ($176,100 for 2025) - stops withholding after cap
# - Additional Medicare Tax (0.9% on wages over $200K)
# - Allowance deduction before withholding calculation
#
class GuamTaxCalculator
  # Pay frequency to periods per year mapping
  PAY_FREQUENCIES = {
    "biweekly" => 26,
    "weekly" => 52,
    "semimonthly" => 24,
    "monthly" => 12
  }.freeze

  attr_reader :tax_table, :allowances, :pay_frequency, :periods_per_year

  def initialize(tax_year:, filing_status:, pay_frequency:, allowances: 0)
    @tax_table = TaxTable.find_table(
      tax_year: tax_year,
      filing_status: FilingStatusConfig.normalize(filing_status),
      pay_frequency: pay_frequency
    )
    @allowances = allowances
    @pay_frequency = pay_frequency
    @periods_per_year = PAY_FREQUENCIES[pay_frequency]
  end

  # Calculate all taxes for a pay period
  #
  # @param gross_pay [Decimal] Gross pay for this pay period
  # @param ytd_gross [Decimal] Year-to-date gross pay BEFORE this pay period
  # @param ytd_ss_tax [Decimal] Year-to-date Social Security tax withheld (optional)
  # @return [Hash] { withholding:, social_security:, medicare: }
  def calculate(gross_pay:, ytd_gross: 0, ytd_ss_tax: 0, withholding_gross: nil,
                reported_tips: 0, ytd_ss_taxable_wages: nil, ytd_medicare_wages: nil)
    withholding_wages = withholding_gross.nil? ? gross_pay : withholding_gross
    bases = taxable_bases(
      gross_pay: gross_pay,
      reported_tips: reported_tips,
      ytd_ss_taxable_wages: ytd_ss_taxable_wages.nil? ? ytd_gross : ytd_ss_taxable_wages,
      ytd_medicare_wages: ytd_medicare_wages.nil? ? ytd_gross : ytd_medicare_wages
    )
    employee_ss = ((bases[:social_security_wages] + bases[:social_security_tips]) * tax_table.ss_rate).round(2)
    base_medicare = (bases[:medicare_wages] * tax_table.medicare_rate).round(2)
    additional_medicare = (bases[:additional_medicare_wages] * tax_table.additional_medicare_rate).round(2)
    {
      withholding: calculate_withholding(withholding_wages),
      social_security: employee_ss,
      medicare: (base_medicare + additional_medicare).round(2),
      employer_social_security: employee_ss,
      employer_medicare: base_medicare,
      additional_medicare: additional_medicare,
      fit_taxable_wages: withholding_wages.round(2),
      social_security_taxable_wages: bases[:social_security_wages],
      social_security_taxable_tips: bases[:social_security_tips],
      medicare_taxable_wages: bases[:medicare_wages],
      additional_medicare_taxable_wages: bases[:additional_medicare_wages]
    }
  end

  def rule_snapshot
    {
      "engine" => "legacy_tax_table",
      "tax_table_id" => tax_table.id,
      "tax_year" => tax_table.tax_year,
      "tax_table_updated_at" => tax_table.updated_at&.iso8601,
      "filing_status" => tax_table.filing_status,
      "pay_frequency" => tax_table.pay_frequency,
      "standard_deduction" => tax_table.standard_deduction.to_f,
      "allowance_amount" => tax_table.allowance_amount.to_f,
      "social_security_wage_base" => tax_table.ss_wage_base.to_f,
      "social_security_rate" => tax_table.ss_rate.to_f,
      "medicare_rate" => tax_table.medicare_rate.to_f,
      "additional_medicare_rate" => tax_table.additional_medicare_rate.to_f,
      "additional_medicare_threshold" => tax_table.additional_medicare_threshold.to_f,
      "brackets" => tax_table.brackets.map do |bracket|
        bracket.transform_values do |value|
          value.is_a?(Float) && !value.finite? ? nil : value
        end
      end
    }
  end

  def taxable_bases(gross_pay:, reported_tips:, ytd_ss_taxable_wages:, ytd_medicare_wages:)
    gross = gross_pay.to_d
    reported_tip_amount = reported_tips.to_d

    if gross.negative? || reported_tip_amount.negative?
      # Correction rows store signed deltas. Preserve the signed wage/tip
      # components so annual and quarterly reports reverse the same buckets
      # as the original paycheck.
      tips = [ reported_tip_amount, 0.to_d ].min
      wages_only = gross - tips
      ss_wages = wages_only
      ss_tips = tips
    else
      tips = reported_tip_amount
      wages_only = [ gross - tips, 0.to_d ].max
      remaining_ss = [ tax_table.ss_wage_base.to_d - ytd_ss_taxable_wages.to_d, 0.to_d ].max
      ss_wages = [ wages_only, remaining_ss ].min
      remaining_after_wages = [ remaining_ss - ss_wages, 0.to_d ].max
      ss_tips = [ tips, remaining_after_wages ].min
    end

    prior_excess = [ ytd_medicare_wages.to_d - tax_table.additional_medicare_threshold.to_d, 0.to_d ].max
    current_excess = [ ytd_medicare_wages.to_d + gross - tax_table.additional_medicare_threshold.to_d, 0.to_d ].max

    {
      social_security_wages: ss_wages.round(2),
      social_security_tips: ss_tips.round(2),
      medicare_wages: gross.round(2),
      additional_medicare_wages: (current_excess - prior_excess).round(2)
    }
  end

  # Calculate federal/Guam income tax withholding
  #
  # Per IRS Publication 15-T, the withholding is calculated by:
  # 1. Subtracting the allowance amount from gross pay
  # 2. Finding the applicable bracket
  # 3. Applying the base tax + rate on excess
  def calculate_withholding(gross_pay)
    # Apply allowance deduction
    allowance_deduction = allowances * allowance_per_period
    taxable_income = [ gross_pay - allowance_deduction, 0 ].max

    # Find the applicable bracket
    bracket = tax_table.find_bracket(taxable_income)

    return 0.0 unless bracket

    # Calculate withholding: base_tax + (income - min_income) * rate
    # The threshold is the min_income of the bracket
    excess = [ taxable_income - bracket[:min_income], 0 ].max
    withholding = bracket[:base_tax] + (excess * bracket[:rate])

    withholding.round(2)
  end

  # Calculate Social Security tax (OASDI)
  #
  # Key: Check wage base cap!
  # Once YTD wages reach the cap ($176,100 for 2025), stop withholding.
  def calculate_social_security(gross_pay, ytd_gross)
    # Calculate how much room is left under the wage base cap
    remaining_taxable = [ tax_table.ss_wage_base - ytd_gross, 0 ].max

    # Only tax up to the remaining room under the cap
    taxable_wages = [ gross_pay, remaining_taxable ].min

    # Apply SS rate (6.2%)
    (taxable_wages * tax_table.ss_rate).round(2)
  end

  # Calculate Medicare tax
  #
  # Key: Additional Medicare Tax!
  # Base rate: 1.45% on all wages
  # Additional: 0.9% on wages over $200K (single)
  def calculate_medicare(gross_pay, ytd_gross)
    # Base Medicare tax
    base_medicare = (gross_pay * tax_table.medicare_rate).round(2)

    # Check for Additional Medicare Tax (0.9% on wages over threshold)
    additional_medicare = 0.0

    if ytd_gross + gross_pay > tax_table.additional_medicare_threshold
      # Calculate how much of this paycheck is over the threshold
      threshold = tax_table.additional_medicare_threshold
      additional_rate = tax_table.additional_medicare_rate

      if ytd_gross >= threshold
        # All of this paycheck is over the threshold
        additional_medicare = (gross_pay * additional_rate).round(2)
      else
        # Only part of this paycheck is over the threshold
        amount_over_threshold = (ytd_gross + gross_pay) - threshold
        additional_medicare = (amount_over_threshold * additional_rate).round(2)
      end
    end

    base_medicare + additional_medicare
  end

  # Employer Medicare does not include additional medicare surcharge
  def calculate_employer_medicare(gross_pay)
    (gross_pay * tax_table.medicare_rate).round(2)
  end

  private

  # Get allowance amount per pay period
  # This is the per-period allowance deduction from the tax table
  def allowance_per_period
    tax_table.allowance_amount || 0
  end
end
