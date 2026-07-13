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

  def apply_loan_payments!
    process_loan_payments
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
          w4_step4b_deductions: employee.w4_step4b_deductions.to_f,
          w4_form_version: employee.w4_form_version
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

  # Tips already paid directly to the employee still have to be included in
  # taxable/reported tips before being offset from the paycheck. If an operator
  # enters only "tips paid out," promote that amount into reported_tips so gross
  # wages, FIT, FICA, W-2GU, and quarterly reports do not understate tips.
  def normalize_tips_paid_out_into_reported_tips!
    return if payroll_item.correction_entry?

    tips_paid_out = BigDecimal(payroll_item.tips_paid_out.to_s.presence || "0")
    reported_tips = BigDecimal(payroll_item.reported_tips.to_s.presence || "0")
    return unless tips_paid_out.positive? && reported_tips < tips_paid_out

    payroll_item.reported_tips = tips_paid_out.round(2)
  rescue ArgumentError
    nil
  end

  def ytd_gross_before
    ytd_before_totals[:gross_pay]
  end

  def ytd_ss_before
    ytd_before_totals[:social_security_tax]
  end

  def ytd_ss_taxable_wages_before
    ytd_before_totals[:social_security_taxable_total]
  end

  def ytd_medicare_wages_before
    ytd_before_totals[:medicare_taxable_wages]
  end

  def calculate_taxes(withholding_gross: payroll_item.gross_pay)
    tax_args = {
      gross_pay: payroll_item.gross_pay,
      ytd_gross: ytd_gross_before,
      ytd_ss_tax: ytd_ss_before,
      withholding_gross: withholding_gross,
      reported_tips: payroll_item.cash_tips_reported.to_f,
      ytd_ss_taxable_wages: ytd_ss_taxable_wages_before,
      ytd_medicare_wages: ytd_medicare_wages_before
    }
    if tax_calculator.method(:calculate).parameters.any? { |type, name| [ :key, :keyreq ].include?(type) && name == :w4_dependent_credit }
      tax_args[:w4_dependent_credit] = employee.w4_dependent_credit.to_f
    end

    taxes = tax_calculator.calculate(**tax_args)

    calculated_withholding = taxes[:withholding].to_f
    if payroll_item.withholding_tax_override.present?
      payroll_item.withholding_tax = payroll_item.withholding_tax_override.to_f
    else
      payroll_item.withholding_tax = [ calculated_withholding + payroll_item.withholding_tax_adjustment.to_f, 0 ].max
    end
    payroll_item.social_security_tax = taxes[:social_security]
    payroll_item.medicare_tax = taxes[:medicare]

    payroll_item.employer_social_security_tax = taxes[:employer_social_security]
    payroll_item.employer_medicare_tax = taxes[:employer_medicare]
    payroll_item.additional_medicare_tax = taxes[:additional_medicare]
    payroll_item.fit_taxable_wages = taxes[:fit_taxable_wages]
    payroll_item.social_security_taxable_wages = taxes[:social_security_taxable_wages]
    payroll_item.social_security_taxable_tips = taxes[:social_security_taxable_tips]
    payroll_item.medicare_taxable_wages = taxes[:medicare_taxable_wages]
    payroll_item.additional_medicare_taxable_wages = taxes[:additional_medicare_taxable_wages]
    payroll_item.annual_tax_config = tax_calculator.respond_to?(:annual_config) ? tax_calculator.annual_config : nil
    sync_additional_withholding_from_employee!
    payroll_item.tax_rule_snapshot = tax_calculator.rule_snapshot.merge(employee_w4_snapshot)
  end

  def capture_payroll_reporting_components!
    payroll_item.cash_tips_reported = payroll_item.reported_tips.to_d.round(2)
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
  def calculate_base_gross_for_payroll_fields
    @exclude_payroll_field_entry_totals = true
    calculate_gross_pay
  ensure
    @exclude_payroll_field_entry_totals = false
  end

  def sync_payroll_field_entries_after_base_gross
    restore_capped_payroll_field_entries!
    payroll_item.apply_default_payroll_field_entries_if_unset!(employee, assignments: payroll_field_assignments_for_calculation)
  end

  def sync_percentage_payroll_field_entries_after_final_gross
    payroll_item.refresh_percentage_payroll_field_entries_after_final_gross!(employee, assignments: payroll_field_assignments_for_calculation)
  end

  def payroll_field_assignments_for_calculation
    @payroll_field_assignments_for_calculation ||= payroll_item.active_payroll_field_assignments_for(employee).to_a
  end

  def restore_capped_payroll_field_entries!
    payroll_item.payroll_item_field_entries.each do |entry|
      uncapped_amount = entry.metadata.is_a?(Hash) ? entry.metadata["uncapped_amount"] : nil
      next if uncapped_amount.blank?

      entry.amount = BigDecimal(uncapped_amount.to_s).round(2)
      entry.metadata = entry.metadata.except("uncapped_amount")
    rescue ArgumentError
      next
    end
  end

  def pre_tax_employee_deductions_total
    employee.employee_deductions.active.includes(:deduction_type)
      .reject { |ed| skip_employee_deduction?(ed.deduction_type) }
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
      next if skip_employee_deduction?(dt)

      amount = ed.calculate_amount(payroll_item.gross_pay)
      next if amount.zero?

      payroll_item.payroll_item_deductions.build(
        deduction_type: dt,
        amount: amount,
        category: dt.category,
        label: dt.name,
        reporting_group: reporting_group_for_deduction_type(dt)
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
      record_employer_contribution(
        "401(k) Employer Match",
        payroll_item.employer_retirement_match,
        sub_category: "retirement",
        reporting_group: PayrollReportingGroups::GROUP_401K_PRE_TAX
      )
    end
    if payroll_item.employer_roth_retirement_match.to_f > 0
      record_employer_contribution(
        "Roth 401(k) Employer Match",
        payroll_item.employer_roth_retirement_match,
        sub_category: "retirement",
        reporting_group: PayrollReportingGroups::GROUP_401K_AFTER_TAX
      )
    end

    record_payroll_field_employee_deductions
    record_payroll_field_employer_contributions

    # Update aggregate fields for backward compatibility with existing code
    payroll_item.loan_payment = aggregate_loan
    payroll_item.insurance_payment = aggregate_insurance
  end

  # Process loan balance tracking for any loan-type deductions
  def process_loan_payments
    payroll_item.payroll_item_deductions.select { |pid| pid.deduction_type&.loan? }.each do |pid|
      loan = find_active_loan_for_deduction(pid.deduction_type_id)
      next unless loan
      next if payment_already_recorded?(loan)

      loan.record_payment!(
        amount: pid.amount,
        pay_period: pay_period,
        payroll_item: payroll_item,
        date: pay_period.pay_date
      )
    end
  end

  def custom_earnings_total
    total = Array(payroll_item.custom_earnings).sum { |ce| ce["amount"].to_f } +
      payroll_item.taxable_payroll_adjustments_total
    total += payroll_item.taxable_payroll_field_entries_total unless @exclude_payroll_field_entry_totals
    total
  end

  def custom_deductions_total
    payroll_item.custom_deductions_total + payroll_item.post_tax_payroll_adjustments_total
  end

  def pre_tax_payroll_adjustments_total
    payroll_item.pre_tax_payroll_adjustments_total
  end

  def non_taxable_additions_total
    payroll_item.non_taxable_pay.to_f +
      payroll_item.non_taxable_payroll_adjustments_total +
      payroll_item.non_taxable_payroll_field_entries_total
  end

  def record_payroll_field_employer_contributions
    payroll_item.payroll_item_field_entries.each do |entry|
      next unless entry.active? && entry.employer_contribution? && entry.amount.to_f.positive?

      record_employer_contribution(entry.label, entry.amount, sub_category: entry.category, reporting_group: entry.reporting_group)
    end
  end

  def record_payroll_field_employee_deductions
    payroll_item.payroll_item_field_entries.each do |entry|
      next unless entry.active? && entry.kind == "deduction" && entry.amount.to_f.positive?
      next unless entry.tax_treatment.in?(%w[pre_tax_deduction post_tax_deduction])

      category = entry.tax_treatment == "pre_tax_deduction" ? "pre_tax" : "post_tax"
      deduction_type = find_or_create_payroll_field_deduction_type(entry.label, category: category, sub_category: entry.category, reporting_group: entry.reporting_group)
      payroll_item.payroll_item_deductions.build(
        deduction_type: deduction_type,
        amount: entry.amount,
        category: category,
        label: entry.label,
        reporting_group: entry.reporting_group
      )
    end
  end

  def calculate_totals
    payroll_item.total_additions = (
      payroll_item.reported_tips.to_f +
      payroll_item.service_charge_wages.to_f +
      payroll_item.bonus.to_f +
      custom_earnings_total +
      non_taxable_additions_total
    ).round(2)

    itemized_pre_tax = 0.0
    itemized_post_tax = 0.0
    itemized_loan_payment = 0.0

    payroll_item.payroll_item_deductions.each do |deduction|
      amount = deduction.amount.to_f

      if deduction.post_tax?
        itemized_post_tax += amount
        itemized_loan_payment += amount if deduction.deduction_type&.loan?
      elsif deduction.pre_tax?
        itemized_pre_tax += amount
      end
    end

    direct_loan_payment = 0.0

    # Imports and the Adjust Hours grid can provide the paycheck loan deduction
    # directly. That value is authoritative for this payroll run even if the
    # employee also has itemized EmployeeLoan records configured; those records
    # are separate loan-tracking setup and must not hide or duplicate the direct
    # paycheck deduction.
    if payroll_item.loan_deduction.to_f > 0
      direct_loan_payment = payroll_item.loan_deduction.to_f
      payroll_item.loan_payment = direct_loan_payment
    end

    has_itemized_deductions = payroll_item.payroll_item_deductions.any?

    # Total deductions: taxes + pre-tax retirement + pre-tax deductions + post-tax deductions
    legacy_insurance_payment = has_itemized_deductions ? 0.0 : payroll_item.insurance_payment.to_f

    post_tax_deductions = if direct_loan_payment.positive?
      (itemized_post_tax - itemized_loan_payment) + direct_loan_payment + legacy_insurance_payment
    elsif has_itemized_deductions
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
      pre_tax_payroll_adjustments_total +
      post_tax_deductions +
      custom_deductions_total +
      payroll_item.tips_paid_out.to_f
    ).round(2)

    cap_additional_withholding_to_available_pay!
  end

  def calculate_net_pay
    cap_deductions_to_available_pay!

    payroll_item.net_pay = (
      payroll_item.gross_pay -
      payroll_item.total_deductions +
      non_taxable_additions_total
    ).round(2)
    payroll_item.net_pay = 0.0 if payroll_item.net_pay.negative? && !payroll_item.correction_entry?
  end

  def update_ytd_on_item
    ytd = ytd_before_totals

    payroll_item.ytd_gross = ytd[:gross_pay].to_f + payroll_item.gross_pay.to_f
    payroll_item.ytd_net = ytd[:net_pay].to_f + payroll_item.net_pay.to_f
    payroll_item.ytd_withholding_tax = ytd[:withholding_tax].to_f + payroll_item.withholding_tax.to_f
    payroll_item.ytd_social_security_tax = ytd[:social_security_tax].to_f + payroll_item.social_security_tax.to_f
    payroll_item.ytd_medicare_tax = ytd[:medicare_tax].to_f + payroll_item.medicare_tax.to_f
    payroll_item.ytd_retirement = ytd[:retirement].to_f + payroll_item.retirement_payment.to_f
    payroll_item.ytd_roth_retirement = ytd[:roth_retirement].to_f + payroll_item.roth_retirement_payment.to_f
  end

  private

  def employee_w4_snapshot
    {
      "w4" => {
        "form_version" => employee.w4_form_version,
        "effective_on" => employee.w4_effective_on&.iso8601,
        "filing_status_entered" => employee.filing_status,
        "filing_status_normalized" => employee.normalized_filing_status,
        "step2_multiple_jobs" => employee.w4_step2_multiple_jobs,
        "step3_dependent_credit" => employee.w4_dependent_credit.to_f,
        "step4a_other_income" => employee.w4_step4a_other_income.to_f,
        "step4b_deductions" => employee.w4_step4b_deductions.to_f,
        "step4c_extra_withholding" => payroll_item.additional_withholding.to_f,
        "step4c_configured_extra_withholding" => employee.additional_withholding.to_f,
        "step4c_override" => payroll_item.additional_withholding_override&.to_f,
        "legacy_allowances" => employee.allowances
      }
    }
  end

  def ytd_before_totals
    @ytd_before_totals ||= employee.ytd_totals_before(
      year: pay_period.pay_date.year,
      pay_date: pay_period.pay_date,
      pay_period_id: pay_period.id
    )
  end

  def find_or_create_payroll_field_deduction_type(label, category:, sub_category: "other", reporting_group: nil)
    company = payroll_item.company || pay_period.company
    sub_category = DeductionType::SUB_CATEGORIES.include?(sub_category.to_s) ? sub_category.to_s : "other"
    normalized_group = PayrollReportingGroups.normalize(reporting_group)
    name = payroll_field_deduction_type_name(label, category, company: company)
    existing = company.deduction_types.find_by(name: name, category: category)
    if existing
      existing.update!(reporting_group: normalized_group) if normalized_group.present? && existing.reporting_group.blank?
      return existing
    end

    attrs = {
      name: name,
      category: category,
      sub_category: sub_category
    }
    attrs[:reporting_group] = normalized_group if normalized_group.present?
    company.deduction_types.create!(**attrs)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    existing = company.deduction_types.find_by(name: name, category: category)
    return existing if existing

    raise e
  end

  def payroll_field_deduction_type_name(label, category, company: nil)
    category_label = category.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
    base_name = "Payroll Field: #{label} (#{category_label})"
    return base_name unless company

    same_name = company.deduction_types.where(name: base_name)
    return base_name if same_name.blank? || same_name.exists?(category: category)

    "Payroll Field #{category_label}: #{label}"
  end

  def record_employer_contribution(label, amount, sub_category: "retirement", reporting_group: nil)
    return if amount.to_f.zero?

    sub_category = DeductionType::SUB_CATEGORIES.include?(sub_category.to_s) ? sub_category.to_s : "other"
    normalized_group = PayrollReportingGroups.normalize(reporting_group)

    # Employer contributions don't need a DeductionType row — use a virtual record
    payroll_item.payroll_item_deductions.build(
      deduction_type_id: find_or_create_employer_deduction_type(label, sub_category: sub_category, reporting_group: normalized_group).id,
      amount: amount,
      category: "employer_contribution",
      label: label,
      reporting_group: normalized_group
    )
  end

  def find_or_create_employer_deduction_type(label, sub_category: "retirement", reporting_group: nil)
    company = payroll_item.company || pay_period.company
    sub_category = DeductionType::SUB_CATEGORIES.include?(sub_category.to_s) ? sub_category.to_s : "other"
    normalized_group = PayrollReportingGroups.normalize(reporting_group)
    existing = company.deduction_types.find_by(name: label, category: "employer_contribution")
    if existing
      existing.update!(reporting_group: normalized_group) if normalized_group.present? && existing.reporting_group.blank?
      return existing
    end

    if sub_category == "retirement"
      legacy = company.deduction_types.find_by(name: label, category: "pre_tax", sub_category: "retirement")
      return ensure_employer_contribution_type!(legacy, reporting_group: normalized_group) if legacy
    end

    attrs = {
      name: label,
      category: "employer_contribution",
      sub_category: sub_category
    }
    attrs[:reporting_group] = normalized_group if normalized_group.present?
    company.deduction_types.create!(**attrs)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    existing = company.deduction_types.find_by(name: label, category: "employer_contribution")
    return existing if existing

    raise e
  end

  def reporting_group_for_deduction_type(deduction_type)
    PayrollReportingGroups.infer_retirement_group(
      explicit_group: deduction_type&.reporting_group,
      label: deduction_type&.name,
      category: deduction_type&.sub_category,
      deduction_category: deduction_type&.category
    )
  end

  def skip_employee_deduction?(deduction_type)
    return true if payroll_item.loan_deduction.to_f.positive? && deduction_type&.loan?
    return false unless deduction_type&.sub_category == "retirement"
    return employee.roth_retirement_rate.to_f.positive? if roth_retirement_deduction?(deduction_type)

    employee.retirement_rate.to_f.positive?
  end

  def find_active_loan_for_deduction(deduction_type_id)
    if employee.association(:employee_loans).loaded?
      employee.employee_loans.find { |loan| loan.active? && loan.deduction_type_id == deduction_type_id }
    else
      employee.employee_loans.active.find_by(deduction_type_id: deduction_type_id)
    end
  end

  def payment_already_recorded?(loan)
    if loan.association(:loan_transactions).loaded?
      loan.loan_transactions.any? { |transaction| transaction.transaction_type == "payment" && transaction.payroll_item_id == payroll_item.id }
    else
      loan.loan_transactions.payments.exists?(payroll_item_id: payroll_item.id)
    end
  end

  def roth_retirement_deduction?(deduction_type)
    deduction_type.category == "post_tax" || deduction_type.name.to_s.match?(/roth/i)
  end

  def cap_additional_withholding_to_available_pay!
    return if payroll_item.correction_entry?
    return unless payroll_item.additional_withholding.to_f.positive?

    available_pay = payroll_item.gross_pay.to_f + non_taxable_additions_total
    excess = payroll_item.total_deductions.to_f - available_pay
    return unless excess.positive?

    reduction = [ excess, payroll_item.additional_withholding.to_f ].min
    payroll_item.additional_withholding = (payroll_item.additional_withholding.to_f - reduction).round(2)
    payroll_item.total_deductions = (payroll_item.total_deductions.to_f - reduction).round(2)
  end

  def cap_deductions_to_available_pay!
    return if payroll_item.correction_entry?

    available_pay = (payroll_item.gross_pay.to_f + non_taxable_additions_total).round(2)
    excess = (payroll_item.total_deductions.to_f - available_pay).round(2)
    return unless excess.positive?

    had_itemized_deductions = payroll_item.payroll_item_deductions.any?

    remaining = reduce_custom_deductions_by!(excess)
    remaining = reduce_payroll_field_deductions_by!(remaining)
    remaining = reduce_payroll_item_deductions_by!(remaining)
    sync_aggregate_deductions_from_itemized! if had_itemized_deductions

    [
      :additional_withholding,
      :withholding_tax,
      :roth_retirement_payment,
      :retirement_payment,
      :loan_payment,
      :insurance_payment,
      :medicare_tax,
      :social_security_tax,
      :tips_paid_out
    ].each do |field|
      remaining = reduce_numeric_deduction_field_by!(field, remaining)
      break unless remaining.positive?
    end

    payroll_item.total_deductions = [ (payroll_item.total_deductions.to_f - (excess - remaining)).round(2), available_pay ].min
  end

  def reduce_numeric_deduction_field_by!(field, amount)
    return amount unless amount.positive?

    current = payroll_item.public_send(field).to_f
    reduction = [ current, amount ].min
    payroll_item.public_send("#{field}=", (current - reduction).round(2))
    (amount - reduction).round(2)
  end

  def reduce_custom_deductions_by!(amount)
    return amount unless amount.positive?

    deductions = Array(payroll_item.custom_deductions).map(&:dup)
    deductions.reverse_each do |deduction|
      current = deduction["amount"].to_f
      reduction = [ current, amount ].min
      deduction["amount"] = (current - reduction).round(2)
      amount = (amount - reduction).round(2)
      break unless amount.positive?
    end

    payroll_item.custom_deductions = deductions.select { |deduction| deduction["amount"].to_f.positive? }
    amount
  end

  def reduce_payroll_field_deductions_by!(amount)
    return amount unless amount.positive?

    deductions = payroll_item.payroll_item_field_entries.select do |entry|
      entry.active? && entry.tax_treatment.in?(%w[pre_tax_deduction post_tax_deduction])
    end

    ActiveRecord::Associations::Preloader.new(records: payroll_item.payroll_item_deductions, associations: :deduction_type).call

    deductions.reverse_each do |entry|
      current = entry.amount.to_f
      reduction = [ current, amount ].min
      metadata = entry.metadata || {}
      entry.metadata = metadata.merge("uncapped_amount" => current.round(2)) if reduction.positive? && !metadata.key?("uncapped_amount")
      next_amount = (current - reduction).round(2)
      entry.amount = next_amount
      payroll_item.payroll_item_deductions.each do |deduction|
        deduction_category = entry.tax_treatment == "pre_tax_deduction" ? "pre_tax" : "post_tax"
        next unless deduction.category == deduction_category
        next unless deduction.deduction_type&.name == payroll_field_deduction_type_name(entry.label, deduction_category, company: payroll_item.company || pay_period.company)

        deduction.amount = next_amount
      end
      amount = (amount - reduction).round(2)
      break unless amount.positive?
    end

    payroll_item.payroll_item_deductions.select { |deduction| deduction.amount.to_f.zero? }.each do |deduction|
      deduction.destroy! if deduction.persisted?
      payroll_item.payroll_item_deductions.target.delete(deduction)
    end

    amount
  end

  def reduce_payroll_item_deductions_by!(amount)
    return amount unless amount.positive?

    employee_deductions = payroll_item.payroll_item_deductions.select { |deduction| deduction.pre_tax? || deduction.post_tax? }

    employee_deductions.reverse_each do |deduction|
      current = deduction.amount.to_f
      reduction = [ current, amount ].min
      deduction.amount = (current - reduction).round(2)
      amount = (amount - reduction).round(2)
      break unless amount.positive?
    end

    employee_deductions.select { |deduction| deduction.amount.to_f.zero? }.each do |deduction|
      deduction.destroy! if deduction.persisted?
      payroll_item.payroll_item_deductions.target.delete(deduction)
    end

    amount
  end

  def sync_aggregate_deductions_from_itemized!
    payroll_item.loan_payment = payroll_item.payroll_item_deductions.sum do |deduction|
      deduction.deduction_type&.loan? ? deduction.amount.to_f : 0.0
    end.round(2)
    payroll_item.insurance_payment = payroll_item.payroll_item_deductions.sum do |deduction|
      deduction.deduction_type&.sub_category == "insurance" ? deduction.amount.to_f : 0.0
    end.round(2)
  end

  def sync_additional_withholding_from_employee!
    # Rehydrate before every calculation so a previous zero-pay cap does not
    # suppress the employee's configured W-4 extra withholding on recalculation.
    payroll_item.additional_withholding =
      if payroll_item.additional_withholding_override.present?
        payroll_item.additional_withholding_override.to_f
      else
        employee.additional_withholding.to_f
      end
  end

  def ensure_employer_contribution_type!(deduction_type, reporting_group: nil)
    normalized_group = PayrollReportingGroups.normalize(reporting_group)
    if deduction_type.employer_contribution?
      deduction_type.update!(reporting_group: normalized_group) if normalized_group.present? && deduction_type.reporting_group.blank?
      return deduction_type
    end

    if deduction_type.employee_deductions.exists?
      deduction_type.errors.add(:base, "#{deduction_type.name} is already used by employee deductions and cannot be repurposed as an employer contribution")
      raise ActiveRecord::RecordInvalid.new(deduction_type)
    end

    attrs = { category: "employer_contribution" }
    attrs[:reporting_group] = normalized_group if normalized_group.present?
    deduction_type.update!(attrs)
    deduction_type
  end
end
