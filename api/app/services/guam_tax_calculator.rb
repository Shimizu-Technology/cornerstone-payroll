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
      filing_status: filing_status,
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
  def calculate(gross_pay:, ytd_gross: 0, ytd_ss_tax: 0)
    {
      withholding: calculate_withholding(gross_pay),
      social_security: calculate_social_security(gross_pay, ytd_gross),
      medicare: calculate_medicare(gross_pay, ytd_gross)
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

    # Calculate withholding: base_tax + (income - threshold) * rate
    excess = [ taxable_income - bracket[:threshold], 0 ].max
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

  private

  # Get allowance amount per pay period
  # This is the per-period allowance deduction from the tax table
  def allowance_per_period
    tax_table.allowance_amount || 0
  end
end
