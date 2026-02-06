# frozen_string_literal: true

# Guam Tax Calculator V2
#
# Uses the new normalized tax configuration schema:
# - AnnualTaxConfig (one per year)
# - FilingStatusConfig (standard deduction per status)
# - TaxBracket (7 brackets per status)
#
# Key features:
# - Stores ANNUAL values, calculates per-period amounts automatically
# - SS wage base cap - stops withholding after cap reached
# - Additional Medicare Tax (0.9% on wages over $200K)
# - No allowances (modern W-4) - standard deduction only
#
class GuamTaxCalculatorV2
  # Pay frequency to periods per year mapping
  PAY_FREQUENCIES = {
    "biweekly" => 26,
    "weekly" => 52,
    "semimonthly" => 24,
    "monthly" => 12
  }.freeze

  attr_reader :config, :filing_status_config, :pay_frequency, :periods_per_year

  def initialize(tax_year:, filing_status:, pay_frequency:)
    @config = AnnualTaxConfig.find_by!(tax_year: tax_year)
    @filing_status_config = @config.filing_status_configs.find_by!(filing_status: filing_status)
    @pay_frequency = pay_frequency
    @periods_per_year = PAY_FREQUENCIES[pay_frequency]
  end

  # Calculate all taxes for a pay period
  #
  # @param gross_pay [Decimal] Gross pay for this pay period
  # @param ytd_gross [Decimal] Year-to-date gross pay BEFORE this pay period
  # @return [Hash] { withholding:, social_security:, medicare: }
  def calculate(gross_pay:, ytd_gross: 0)
    {
      withholding: calculate_withholding(gross_pay),
      social_security: calculate_social_security(gross_pay, ytd_gross),
      medicare: calculate_medicare(gross_pay, ytd_gross)
    }
  end

  # Calculate federal/Guam income tax withholding
  #
  # Per IRS Publication 15-T percentage method:
  # 1. Get per-period gross pay
  # 2. Subtract per-period standard deduction
  # 3. Annualize the taxable amount
  # 4. Apply annual tax brackets
  # 5. De-annualize the tax
  def calculate_withholding(gross_pay)
    # Per-period standard deduction
    period_std_deduction = filing_status_config.standard_deduction / periods_per_year

    # Taxable income for this period (after standard deduction)
    period_taxable = [ gross_pay - period_std_deduction, 0 ].max

    # Annualize the taxable income
    annual_taxable = period_taxable * periods_per_year

    # Calculate annual tax using brackets
    annual_tax = calculate_from_brackets(annual_taxable)

    # De-annualize to get per-period withholding
    (annual_tax / periods_per_year).round(2)
  end

  # Calculate Social Security tax (OASDI)
  #
  # Key: Check wage base cap!
  # Once YTD wages reach the cap, stop withholding.
  def calculate_social_security(gross_pay, ytd_gross)
    # Calculate how much room is left under the wage base cap
    remaining_taxable = [ config.ss_wage_base - ytd_gross, 0 ].max

    # Only tax up to the remaining room under the cap
    taxable_wages = [ gross_pay, remaining_taxable ].min

    # Apply SS rate (6.2%)
    (taxable_wages * config.ss_rate).round(2)
  end

  # Calculate Medicare tax
  #
  # Key: Additional Medicare Tax!
  # Base rate: 1.45% on all wages
  # Additional: 0.9% on wages over threshold
  def calculate_medicare(gross_pay, ytd_gross)
    # Base Medicare tax
    base_medicare = (gross_pay * config.medicare_rate).round(2)

    # Check for Additional Medicare Tax
    additional_medicare = 0.0
    threshold = config.additional_medicare_threshold

    if ytd_gross + gross_pay > threshold
      additional_rate = config.additional_medicare_rate

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

  # Apply progressive tax brackets to annual taxable income
  def calculate_from_brackets(annual_taxable)
    tax = 0.0
    remaining = annual_taxable

    filing_status_config.tax_brackets.each do |bracket|
      break if remaining <= 0

      # How much income falls in this bracket?
      bracket_max = bracket.max_income || Float::INFINITY
      bracket_range = bracket_max - bracket.min_income
      taxable_in_bracket = [ remaining, bracket_range ].min

      # Add tax for this bracket
      tax += taxable_in_bracket * bracket.rate

      remaining -= taxable_in_bracket
    end

    tax.round(2)
  end
end
