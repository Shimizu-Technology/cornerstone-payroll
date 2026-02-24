# frozen_string_literal: true

# Base PayrollCalculator with Strategy Pattern
#
# Usage:
#   calculator = PayrollCalculator.for(employee, payroll_item)
#   calculator.calculate
#
# This is a port from the leon-tax-calculator codebase with enhancements:
# - Uses GuamTaxCalculatorV2 (annual tax config)
# - SS wage base cap
# - Additional Medicare Tax
#
class PayrollCalculator
  attr_reader :employee, :payroll_item

  # Factory method - returns the appropriate calculator type
  def self.for(employee, payroll_item)
    case employee.employment_type
    when "hourly"
      HourlyPayrollCalculator.new(employee, payroll_item)
    when "salary"
      SalaryPayrollCalculator.new(employee, payroll_item)
    else
      raise ArgumentError, "Unknown employment type: #{employee.employment_type}"
    end
  end

  def initialize(employee, payroll_item)
    @employee = employee
    @payroll_item = payroll_item
  end

  def calculate
    raise NotImplementedError, "Subclasses must implement #calculate"
  end

  protected

  # Initialize the tax calculator with employee's info
  # Prefer V2 config; fall back to legacy tax tables if none exist
  def tax_calculator
    @tax_calculator ||= begin
      config = AnnualTaxConfig.current(pay_period.pay_date.year)

      calculator_class = config.present? ? GuamTaxCalculatorV2 : GuamTaxCalculator
      calculator_class.new(
        tax_year: pay_period.pay_date.year,
        filing_status: employee.filing_status,
        pay_frequency: employee.pay_frequency,
        allowances: employee.allowances
      )
    end
  end

  def pay_period
    @pay_period ||= payroll_item.pay_period
  end

  # Get YTD gross pay BEFORE this payroll item
  def ytd_gross_before
    employee.calculate_ytd_gross(pay_period.pay_date.year)
  end

  # Get YTD SS tax BEFORE this payroll item
  def ytd_ss_before
    employee.calculate_ytd_social_security(pay_period.pay_date.year)
  end

  # Calculate all taxes using GuamTaxCalculator
  def calculate_taxes(withholding_gross: payroll_item.gross_pay)
    taxes = tax_calculator.calculate(
      gross_pay: payroll_item.gross_pay,
      ytd_gross: ytd_gross_before,
      ytd_ss_tax: ytd_ss_before,
      withholding_gross: withholding_gross
    )

    payroll_item.withholding_tax = taxes[:withholding]
    payroll_item.social_security_tax = taxes[:social_security]
    payroll_item.medicare_tax = taxes[:medicare]

    # Employer match taxes
    payroll_item.employer_social_security_tax = taxes[:employer_social_security]
    payroll_item.employer_medicare_tax = taxes[:employer_medicare]

    # Add any additional withholding requested by employee
    payroll_item.additional_withholding = employee.additional_withholding.to_f
  end

  # Calculate retirement deductions (pre-tax)
  def calculate_retirement
    payroll_item.retirement_payment = (payroll_item.gross_pay * employee.retirement_rate.to_f).round(2)
  end

  # Calculate Roth retirement deductions (post-tax)
  def calculate_roth_retirement
    payroll_item.roth_retirement_payment = (payroll_item.gross_pay * employee.roth_retirement_rate.to_f).round(2)
  end

  # Calculate totals
  def calculate_totals
    # Total additions (tips, bonus are already in gross_pay for hourly, separate for salary)
    payroll_item.total_additions = (
      payroll_item.reported_tips.to_f +
      payroll_item.bonus.to_f
    ).round(2)

    # Total deductions
    payroll_item.total_deductions = (
      payroll_item.withholding_tax.to_f +
      payroll_item.social_security_tax.to_f +
      payroll_item.medicare_tax.to_f +
      payroll_item.additional_withholding.to_f +
      payroll_item.retirement_payment.to_f +
      payroll_item.roth_retirement_payment.to_f +
      payroll_item.loan_payment.to_f +
      payroll_item.insurance_payment.to_f
    ).round(2)
  end

  # Calculate net pay
  # Note: Tips and bonus are already included in gross_pay, so we don't add total_additions here.
  # total_additions is a display field only.
  def calculate_net_pay
    payroll_item.net_pay = (
      payroll_item.gross_pay -
      payroll_item.total_deductions
    ).round(2)
  end

  # Update YTD totals on the payroll item
  def update_ytd_on_item
    ytd = employee.ytd_totals_for(pay_period.pay_date.year)

    payroll_item.ytd_gross = ytd.gross_pay.to_f + payroll_item.gross_pay.to_f
    payroll_item.ytd_net = ytd.net_pay.to_f + payroll_item.net_pay.to_f
    payroll_item.ytd_withholding_tax = ytd.withholding_tax.to_f + payroll_item.withholding_tax.to_f
    payroll_item.ytd_social_security_tax = ytd.social_security_tax.to_f + payroll_item.social_security_tax.to_f
    payroll_item.ytd_medicare_tax = ytd.medicare_tax.to_f + payroll_item.medicare_tax.to_f
    payroll_item.ytd_retirement = ytd.retirement.to_f + payroll_item.retirement_payment.to_f
    payroll_item.ytd_roth_retirement = ytd.roth_retirement.to_f + payroll_item.roth_retirement_payment.to_f
  end
end
