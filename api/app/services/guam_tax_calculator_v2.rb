# frozen_string_literal: true

# Guam Tax Calculator V2
#
# Uses the new AnnualTaxConfig, FilingStatusConfig, and TaxBracket models
# instead of the legacy TaxTable model.
#
# Key features:
# - Database-driven tax tables via normalized schema
# - SS wage base cap - stops withholding after cap
# - Additional Medicare Tax (0.9% on wages over threshold)
# - Standard deduction per filing status
#
class GuamTaxCalculatorV2
  # Pay frequency to periods per year mapping
  PAY_FREQUENCIES = {
    "biweekly" => 26,
    "weekly" => 52,
    "semimonthly" => 24,
    "monthly" => 12
  }.freeze

  attr_reader :annual_config, :filing_status_config, :pay_frequency, :periods_per_year, :allowances

  def initialize(tax_year:, filing_status:, pay_frequency:, allowances: 0)
    @annual_config = AnnualTaxConfig.current(tax_year)
    @annual_config = @annual_config.first if @annual_config.is_a?(ActiveRecord::Relation)
    @annual_config ||= raise(ArgumentError, "No tax configuration found for year #{tax_year}")
    @filing_status_config = @annual_config.config_for(filing_status) ||
                            raise(ArgumentError, "No filing status config found for #{filing_status}")
    @pay_frequency = pay_frequency
    @periods_per_year = PAY_FREQUENCIES[pay_frequency] ||
                        raise(ArgumentError, "Unknown pay frequency: #{pay_frequency}")
    @allowances = allowances
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

  # Calculate federal/Guam income tax withholding using progressive tax brackets
  #
  # Per IRS Publication 15-T methodology:
  # 1. Annualize the gross pay
  # 2. Subtract the standard deduction
  # 3. Apply progressive tax brackets
  # 4. De-annualize to get per-period withholding
  def calculate_withholding(gross_pay)
    # Annualize the gross pay
    annual_gross = gross_pay * periods_per_year

    # Apply standard deduction
    standard_deduction = filing_status_config.standard_deduction
    annual_taxable = [ annual_gross - standard_deduction, 0 ].max

    # Calculate tax using progressive brackets
    annual_tax = calculate_progressive_tax(annual_taxable)

    # De-annualize to get per-period withholding
    (annual_tax / periods_per_year).round(2)
  end

  # Calculate Social Security tax (OASDI)
  #
  # Key: Check wage base cap!
  # Once YTD wages reach the cap, stop withholding.
  def calculate_social_security(gross_pay, ytd_gross)
    ss_wage_base = annual_config.ss_wage_base
    ss_rate = annual_config.ss_rate

    # Calculate how much room is left under the wage base cap
    remaining_taxable = [ ss_wage_base - ytd_gross, 0 ].max

    # Only tax up to the remaining room under the cap
    taxable_wages = [ gross_pay, remaining_taxable ].min

    # Apply SS rate
    (taxable_wages * ss_rate).round(2)
  end

  # Calculate Medicare tax
  #
  # Key: Additional Medicare Tax!
  # Base rate on all wages
  # Additional rate on wages over threshold
  def calculate_medicare(gross_pay, ytd_gross)
    medicare_rate = annual_config.medicare_rate
    additional_rate = annual_config.additional_medicare_rate
    threshold = annual_config.additional_medicare_threshold

    # Base Medicare tax
    base_medicare = (gross_pay * medicare_rate).round(2)

    # Check for Additional Medicare Tax
    additional_medicare = 0.0

    if ytd_gross + gross_pay > threshold
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

  # Calculate progressive tax using the tax brackets
  # This applies each bracket's rate only to the income within that bracket
  def calculate_progressive_tax(taxable_income)
    return 0 if taxable_income <= 0

    total_tax = 0.0
    brackets = filing_status_config.tax_brackets.order(:bracket_order)

    brackets.each do |bracket|
      # Income within this bracket
      bracket_min = bracket.min_income
      bracket_max = bracket.max_income || Float::INFINITY

      # Skip if income is below this bracket
      break if taxable_income <= bracket_min

      # Calculate income taxed at this bracket's rate
      income_in_bracket = [ taxable_income, bracket_max ].min - bracket_min
      income_in_bracket = [ income_in_bracket, 0 ].max

      total_tax += income_in_bracket * bracket.rate
    end

    total_tax.round(2)
  end
end
