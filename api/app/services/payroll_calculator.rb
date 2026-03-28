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
# - Itemized deduction tracking (payroll_item_deductions)
# - Earnings breakdown (payroll_item_earnings)
# - Loan balance tracking (employee_loans)
# - Employer retirement match
#
class PayrollCalculator
  attr_reader :employee, :payroll_item

  def self.for(employee, payroll_item)
    case employee.employment_type
    when "hourly"
      HourlyPayrollCalculator.new(employee, payroll_item)
    when "salary"
      SalaryPayrollCalculator.new(employee, payroll_item)
    when "contractor"
      ContractorPayrollCalculator.new(employee, payroll_item)
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

  def tax_calculator
    @tax_calculator ||= begin
      config = AnnualTaxConfig.current(pay_period.pay_date.year)

      if config.present?
        GuamTaxCalculatorV2.new(
          tax_year: pay_period.pay_date.year,
          filing_status: employee.filing_status,
          pay_frequency: employee.pay_frequency,
          allowances: employee.allowances,
          w4_step2_multiple_jobs: employee.w4_step2_multiple_jobs,
          w4_step4a_other_income: employee.w4_step4a_other_income.to_f,
          w4_step4b_deductions: employee.w4_step4b_deductions.to_f
        )
      else
        GuamTaxCalculator.new(
          tax_year: pay_period.pay_date.year,
          filing_status: employee.filing_status,
          pay_frequency: employee.pay_frequency,
          allowances: employee.allowances
        )
      end
    end
  end

  def pay_period
    @pay_period ||= payroll_item.pay_period
  end

  def ytd_gross_before
    employee.calculate_ytd_gross(pay_period.pay_date.year)
  end

  def ytd_ss_before
    employee.calculate_ytd_social_security(pay_period.pay_date.year)
  end

  def calculate_taxes(withholding_gross: payroll_item.gross_pay)
    taxes = tax_calculator.calculate(
      gross_pay: payroll_item.gross_pay,
      ytd_gross: ytd_gross_before,
      ytd_ss_tax: ytd_ss_before,
      withholding_gross: withholding_gross,
      w4_dependent_credit: employee.w4_dependent_credit.to_f
    )

    payroll_item.withholding_tax = taxes[:withholding]
    payroll_item.social_security_tax = taxes[:social_security]
    payroll_item.medicare_tax = taxes[:medicare]

    payroll_item.employer_social_security_tax = taxes[:employer_social_security]
    payroll_item.employer_medicare_tax = taxes[:employer_medicare]

    payroll_item.additional_withholding = employee.additional_withholding.to_f
  end

  def calculate_retirement
    payroll_item.retirement_payment = (payroll_item.gross_pay * employee.retirement_rate.to_f).round(2)
  end

  def calculate_roth_retirement
    payroll_item.roth_retirement_payment = (payroll_item.gross_pay * employee.roth_retirement_rate.to_f).round(2)
  end

  def calculate_employer_retirement_match
    payroll_item.employer_retirement_match =
      (payroll_item.gross_pay * employee.employer_retirement_match_rate.to_f).round(2)
    payroll_item.employer_roth_retirement_match =
      (payroll_item.gross_pay * employee.employer_roth_match_rate.to_f).round(2)
  end

  # Sum of pre-tax EmployeeDeduction amounts (e.g., fixed-dollar 401k contributions).
  # Called before tax calculation so these reduce the FIT withholding base.
  def pre_tax_employee_deductions_total
    employee.employee_deductions.active.includes(:deduction_type)
      .select { |ed| ed.deduction_type.active? && ed.deduction_type.pre_tax? }
      .sum { |ed| ed.calculate_amount(payroll_item.gross_pay) }
  end

  # Apply all employee_deductions and record itemized PayrollItemDeduction records.
  # Also updates the aggregate fields (loan_payment, insurance_payment) for backward compat.
  def apply_employee_deductions
    payroll_item.payroll_item_deductions.clear

    aggregate_loan = 0.0
    aggregate_insurance = 0.0

    active_deductions = employee.employee_deductions.active.includes(:deduction_type)
    active_deductions.each do |ed|
      dt = ed.deduction_type
      next unless dt.active?

      amount = ed.calculate_amount(payroll_item.gross_pay)
      next if amount.zero?

      payroll_item.payroll_item_deductions.build(
        deduction_type: dt,
        amount: amount,
        category: dt.category,
        label: dt.name
      )

      case dt.sub_category
      when "loan"
        aggregate_loan += amount
      when "insurance"
        aggregate_insurance += amount
      end
    end

    # Record employer retirement match as employer_contribution deductions
    if payroll_item.employer_retirement_match.to_f > 0
      record_employer_contribution("401(k) Employer Match", payroll_item.employer_retirement_match)
    end
    if payroll_item.employer_roth_retirement_match.to_f > 0
      record_employer_contribution("Roth 401(k) Employer Match", payroll_item.employer_roth_retirement_match)
    end

    # Update aggregate fields for backward compatibility with existing code
    payroll_item.loan_payment = aggregate_loan if aggregate_loan > 0
    payroll_item.insurance_payment = aggregate_insurance if aggregate_insurance > 0
  end

  # Process loan balance tracking for any loan-type deductions
  def process_loan_payments
    payroll_item.payroll_item_deductions.select { |pid| pid.deduction_type&.loan? }.each do |pid|
      loan = employee.employee_loans.active.find_by(deduction_type_id: pid.deduction_type_id)
      next unless loan

      loan.record_payment!(
        amount: pid.amount,
        pay_period: pay_period,
        payroll_item: payroll_item,
        date: pay_period.pay_date
      )
    end
  end

  def calculate_totals
    payroll_item.total_additions = (
      payroll_item.reported_tips.to_f +
      payroll_item.bonus.to_f +
      payroll_item.non_taxable_pay.to_f
    ).round(2)

    # Sync loan_deduction from import for imported rows
    if payroll_item.import_source.present? && payroll_item.loan_deduction.to_f > 0
      payroll_item.loan_payment = payroll_item.loan_deduction.to_f
    end

    # Sum itemized deductions from payroll_item_deductions if present
    itemized_post_tax = payroll_item.payroll_item_deductions
      .select(&:post_tax?)
      .sum(&:amount)

    itemized_pre_tax = payroll_item.payroll_item_deductions
      .select(&:pre_tax?)
      .sum(&:amount)

    # Total deductions: taxes + pre-tax retirement + pre-tax deductions + post-tax deductions
    post_tax_deductions = if itemized_post_tax > 0
      itemized_post_tax
    else
      payroll_item.loan_payment.to_f + payroll_item.insurance_payment.to_f
    end

    payroll_item.total_deductions = (
      payroll_item.withholding_tax.to_f +
      payroll_item.social_security_tax.to_f +
      payroll_item.medicare_tax.to_f +
      payroll_item.additional_withholding.to_f +
      payroll_item.retirement_payment.to_f +
      payroll_item.roth_retirement_payment.to_f +
      itemized_pre_tax +
      post_tax_deductions
    ).round(2)
  end

  def calculate_net_pay
    payroll_item.net_pay = (
      payroll_item.gross_pay -
      payroll_item.total_deductions +
      payroll_item.non_taxable_pay.to_f
    ).round(2)
  end

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

  private

  def record_employer_contribution(label, amount)
    return if amount.to_f.zero?

    # Employer contributions don't need a DeductionType row — use a virtual record
    payroll_item.payroll_item_deductions.build(
      deduction_type_id: find_or_create_employer_deduction_type(label).id,
      amount: amount,
      category: "employer_contribution",
      label: label
    )
  end

  def find_or_create_employer_deduction_type(label)
    company = payroll_item.company || pay_period.company
    company.deduction_types.find_or_create_by!(name: label, category: "pre_tax") do |dt|
      dt.sub_category = "retirement"
    end
  end
end
