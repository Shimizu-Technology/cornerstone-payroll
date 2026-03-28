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

  attr_reader :annual_config, :filing_status_config, :pay_frequency, :periods_per_year, :allowances,
              :w4_step2_multiple_jobs, :w4_step4a_other_income, :w4_step4b_deductions

  def initialize(tax_year:, filing_status:, pay_frequency:, allowances: 0,
                 w4_step2_multiple_jobs: false, w4_step4a_other_income: 0, w4_step4b_deductions: 0)
    @annual_config = AnnualTaxConfig.current(tax_year) ||
                     raise(ArgumentError, "No tax configuration found for year #{tax_year}")
    @filing_status_config = @annual_config.config_for(filing_status) ||
                            raise(ArgumentError, "No filing status config found for #{filing_status}")
    @pay_frequency = pay_frequency
    @periods_per_year = PAY_FREQUENCIES[pay_frequency] ||
                        raise(ArgumentError, "Unknown pay frequency: #{pay_frequency}")
    @allowances = allowances
    @w4_step2_multiple_jobs = w4_step2_multiple_jobs
    @w4_step4a_other_income = w4_step4a_other_income.to_f
    @w4_step4b_deductions = w4_step4b_deductions.to_f
  end

  # Calculate all taxes for a pay period
  #
  # @param gross_pay [Decimal] Gross pay for this pay period
  # @param ytd_gross [Decimal] Year-to-date gross pay BEFORE this pay period
  # @param ytd_ss_tax [Decimal] Year-to-date Social Security tax withheld (optional)
  # @return [Hash] { withholding:, social_security:, medicare: }
  def calculate(gross_pay:, ytd_gross: 0, ytd_ss_tax: 0, withholding_gross: nil, w4_dependent_credit: 0)
    withholding_wages = withholding_gross.nil? ? gross_pay : withholding_gross
    employee_ss = calculate_social_security(gross_pay, ytd_gross)
    employee_medicare = calculate_medicare(gross_pay, ytd_gross)

    {
      withholding: calculate_withholding(withholding_wages, w4_dependent_credit: w4_dependent_credit),
      social_security: employee_ss,
      medicare: employee_medicare,
      # Employer match — same rates, same wage base cap for SS
      employer_social_security: employee_ss,  # Same calculation (6.2% capped)
      employer_medicare: calculate_employer_medicare(gross_pay)  # 1.45% no cap, no Additional Medicare
    }
  end

  # Calculate federal/Guam income tax withholding using progressive tax brackets
  #
  # Per IRS Publication 15-T (2020+ W-4) methodology:
  # 1. Annualize the gross pay
  # 2. Add Step 4a other income (annualized)
  # 3. Subtract the standard deduction (halved if Step 2 checkbox is checked)
  # 4. Subtract Step 4b extra deductions
  # 5. Apply progressive tax brackets
  # 6. De-annualize to get per-period withholding
  # 7. Subtract per-period W-4 Step 3 dependent credit
  #
  # Step 2 (Multiple Jobs): Per Pub 15-T, when checked the withholding is
  # computed using the "higher withholding rate" schedule, which effectively
  # halves the standard deduction and bracket widths. We implement this by
  # halving the standard deduction and dividing bracket boundaries by 2.
  #
  # @param gross_pay [Decimal] Gross pay subject to withholding
  # @param w4_dependent_credit [Decimal] Annual W-4 Step 3 credit (default 0)
  def calculate_withholding(gross_pay, w4_dependent_credit: 0)
    annual_gross = gross_pay * periods_per_year

    # Step 4a: Add other income to annualized wages
    annual_gross += w4_step4a_other_income

    # Standard deduction is halved when Step 2 (multiple jobs) is checked
    standard_deduction = filing_status_config.standard_deduction
    effective_deduction = w4_step2_multiple_jobs ? (standard_deduction / 2.0) : standard_deduction

    # Step 4b: Additional deductions claimed on W-4
    total_deduction = effective_deduction + w4_step4b_deductions

    annual_taxable = [ annual_gross - total_deduction, 0 ].max

    # When Step 2 is checked, use half-bracket method per Pub 15-T
    annual_tax = if w4_step2_multiple_jobs
      calculate_progressive_tax_step2(annual_taxable)
    else
      calculate_progressive_tax(annual_taxable)
    end

    # Step 3: Subtract annual dependent credit
    annual_tax_after_credit = [ annual_tax - w4_dependent_credit.to_f, 0 ].max

    # De-annualize to get per-period withholding
    (annual_tax_after_credit / periods_per_year).round(2)
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

  # Employer Medicare — flat 1.45% on ALL wages (no Additional Medicare Tax for employer)
  def calculate_employer_medicare(gross_pay)
    (gross_pay * annual_config.medicare_rate).round(2)
  end

  private

  # Calculate progressive tax using the tax brackets
  # This applies each bracket's rate only to the income within that bracket
  def calculate_progressive_tax(taxable_income)
    return 0 if taxable_income <= 0

    total_tax = 0.0
    brackets = filing_status_config.tax_brackets.order(:bracket_order)

    brackets.each do |bracket|
      bracket_min = bracket.min_income
      bracket_max = bracket.max_income || Float::INFINITY

      break if taxable_income < bracket_min

      income_in_bracket = [ taxable_income, bracket_max ].min - bracket_min
      income_in_bracket = [ income_in_bracket, 0 ].max

      total_tax += income_in_bracket * bracket.rate
    end

    total_tax.round(2)
  end

  # Step 2 "higher withholding rate" schedule per Pub 15-T:
  # Standard deduction is halved (done in calculate_withholding) and bracket
  # boundaries are halved. The tax is NOT doubled — the compressed brackets
  # alone produce the correct higher withholding for employees with multiple
  # income sources.
  def calculate_progressive_tax_step2(taxable_income)
    return 0 if taxable_income <= 0

    total_tax = 0.0
    brackets = filing_status_config.tax_brackets.order(:bracket_order)

    brackets.each do |bracket|
      bracket_min = bracket.min_income / 2.0
      bracket_max = bracket.max_income ? (bracket.max_income / 2.0) : Float::INFINITY

      break if taxable_income < bracket_min

      income_in_bracket = [ taxable_income, bracket_max ].min - bracket_min
      income_in_bracket = [ income_in_bracket, 0 ].max

      total_tax += income_in_bracket * bracket.rate
    end

    total_tax.round(2)
  end
end
