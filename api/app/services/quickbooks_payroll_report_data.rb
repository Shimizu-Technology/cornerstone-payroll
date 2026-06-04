# frozen_string_literal: true

require "ostruct"

# Normalizes pay-period payroll data into QuickBooks-style report buckets while
# preserving Cornerstone's richer payroll detail. This class only classifies
# flexible payroll fields/deductions into 401(k) buckets when an explicit
# reporting_group is present or the source is already retirement/401(k)-specific.
class QuickbooksPayrollReportData
  Line = Struct.new(:label, :amount, :hours, keyword_init: true)
  DeductionContributionEntry = Struct.new(
    :item,
    :employee_name,
    :description,
    :type,
    :employee_amount,
    :company_amount,
    :bucket,
    :reporting_group,
    :source,
    keyword_init: true
  )
  RetirementRow = Struct.new(:group, :employee_name, :employee_amount, :company_amount, keyword_init: true)

  attr_reader :pay_period, :company

  def initialize(pay_period)
    @pay_period = pay_period
    @company = pay_period.company
  end

  def items(include_voided: false)
    @items_by_voided ||= {}
    @items_by_voided[include_voided] ||= begin
      scope = pay_period.payroll_items
        .includes(:employee, :payroll_item_earnings, { payroll_item_field_entries: :payroll_field_definition }, payroll_item_deductions: :deduction_type)
      scope = scope.not_voided unless include_voided
      scope.to_a.sort_by { |item| employee_sort_key(item.employee) }
    end
  end

  def qb_employee_name(employee)
    return "Unknown" unless employee

    first_middle = [ employee.first_name, employee.middle_name ].compact_blank.join(" ")
    return employee.full_name if employee.last_name.blank?
    return employee.last_name if first_middle.blank?

    "#{employee.last_name}, #{first_middle}"
  end

  def pay_date_label
    format_date(pay_period.pay_date)
  end

  def pay_period_label
    "#{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}"
  end

  def qb_date_range_label(include_locations: true)
    suffix = include_locations ? " for all employees from all locations" : " for all employees"
    "From #{format_long_date(pay_period.pay_date)} to #{format_long_date(pay_period.pay_date)}#{suffix}"
  end

  def generated_at_label
    Time.current.in_time_zone("Pacific/Guam").strftime("%b %d, %Y %I:%M %p ChST")
  end

  def earnings_lines_for(item)
    grouped = item.payroll_item_earnings.group_by { |earning| earning.label.presence || earning.category.to_s.titleize }
    lines = [ Line.new(label: "Gross", amount: item.gross_pay.to_f, hours: item.total_hours.to_f) ]

    grouped.each do |label, earnings|
      amount = earnings.sum { |earning| earning.amount.to_f }
      hours = earnings.sum { |earning| earning.hours.to_f }
      next if amount.zero? && hours.zero?

      lines << Line.new(label: label, amount: amount, hours: hours.positive? ? hours : nil)
    end

    existing_categories = item.payroll_item_earnings.map { |earning| earning.category.to_s }
    existing_labels = item.payroll_item_earnings.map { |earning| earning.label.to_s.strip.downcase }

    if item.bonus.to_f.positive? && !existing_categories.include?("bonus")
      lines << Line.new(label: "Bonus", amount: item.bonus.to_f)
    end

    if item.reported_tips.to_f.positive? && !existing_categories.include?("tips")
      lines << Line.new(label: "Paycheck Tips", amount: item.reported_tips.to_f)
    end

    Array(item.custom_earnings).each do |entry|
      amount = entry["amount"].to_f
      label = entry["label"].presence || "Other Earnings"
      next unless amount.positive?
      next if existing_labels.include?(label.to_s.strip.downcase)

      lines << Line.new(label: label, amount: amount)
    end

    payroll_field_entries_for(item, "taxable_addition").each do |entry|
      next unless entry.amount.to_f.positive?

      lines << Line.new(label: entry.label, amount: entry.amount.to_f)
    end

    lines
  end

  def other_pay_lines_for(item)
    lines = []

    item.payroll_item_earnings.select { |earning| earning.category.to_s == "non_taxable" }.each do |earning|
      lines << Line.new(label: earning.label.presence || "Other Pay", amount: earning.amount.to_f, hours: earning.hours)
    end

    payroll_field_entries_for(item, "non_taxable_addition").each do |entry|
      next unless entry.amount.to_f.positive?

      lines << Line.new(label: entry.label, amount: entry.amount.to_f)
    end

    if item.non_taxable_pay.to_f.positive? && lines.none? { |line| line.amount.to_f == item.non_taxable_pay.to_f }
      lines << Line.new(label: "Non-taxable Pay", amount: item.non_taxable_pay.to_f)
    end

    lines
  end

  def pre_tax_retirement_deduction_lines_for(item)
    deduction_contribution_entries_for_item(item)
      .select { |entry| entry.employee_amount.to_f.positive? && entry.bucket == "pre_tax" }
      .map { |entry| Line.new(label: entry.description, amount: entry.employee_amount.to_f) }
  end

  def after_tax_deduction_lines_for(item)
    deduction_contribution_entries_for_item(item)
      .select { |entry| entry.employee_amount.to_f.positive? && entry.bucket == "post_tax" }
      .map { |entry| Line.new(label: entry.description, amount: entry.employee_amount.to_f) }
  end

  def employee_tax_lines_for(item)
    [
      Line.new(label: "Federal Income Tax", amount: item.withholding_tax.to_f),
      Line.new(label: "Social Security", amount: item.social_security_tax.to_f),
      Line.new(label: "Medicare", amount: item.medicare_tax.to_f),
      Line.new(label: "Additional Withholding", amount: item.additional_withholding.to_f)
    ].select { |line| line.amount.to_f.positive? }
  end

  def employer_contribution_lines_for(item)
    entries = deduction_contribution_entries_for_item(item)
      .select { |entry| entry.company_amount.to_f.positive? }
      .map { |entry| Line.new(label: entry.description, amount: entry.company_amount.to_f) }

    entries
  end

  def employee_adjusted_gross(item)
    item.gross_pay.to_f - pre_tax_retirement_deduction_lines_for(item).sum { |line| line.amount.to_f }
  end

  def employee_tax_total(item)
    item.withholding_tax.to_f + item.social_security_tax.to_f + item.medicare_tax.to_f + item.additional_withholding.to_f
  end

  def employee_after_tax_total(item)
    after_tax_deduction_lines_for(item).sum { |line| line.amount.to_f }
  end

  def employer_tax_total(item)
    item.employer_social_security_tax.to_f + item.employer_medicare_tax.to_f
  end

  def employer_contribution_total(item)
    employer_contribution_lines_for(item).sum { |line| line.amount.to_f }
  end

  def total_payroll_cost(item)
    item.gross_pay.to_f + employer_tax_total(item) + employer_contribution_total(item)
  end

  def total_summary
    active = items
    OpenStruct.new(
      name: "Total",
      total_hours: active.sum { |item| item.total_hours.to_f },
      gross_pay: active.sum { |item| item.gross_pay.to_f },
      other_pay: active.sum { |item| other_pay_lines_for(item).sum { |line| line.amount.to_f } },
      employee_taxes: active.sum { |item| employee_tax_total(item) },
      after_tax_deductions: active.sum { |item| employee_after_tax_total(item) },
      net_pay: active.sum { |item| item.net_pay.to_f },
      employer_taxes: active.sum { |item| employer_tax_total(item) },
      employer_contributions: active.sum { |item| employer_contribution_total(item) },
      total_payroll_cost: active.sum { |item| total_payroll_cost(item) }
    )
  end

  def aggregate_lines(lines)
    lines.group_by(&:label).map do |label, grouped|
      Line.new(
        label: label,
        amount: grouped.sum { |line| line.amount.to_f },
        hours: grouped.sum { |line| line.hours.to_f }.then { |hours| hours.positive? ? hours : nil }
      )
    end.sort_by(&:label)
  end

  def deduction_contribution_entries
    @deduction_contribution_entries ||= items.flat_map { |item| build_deduction_contribution_entries(item) }
  end

  def deduction_contribution_entries_for_item(item)
    deduction_contribution_entries.select { |entry| entry.item == item }
  end

  def aggregate_deduction_contribution_rows
    deduction_contribution_entries
      .group_by { |entry| [ entry.description, entry.type, entry.reporting_group ] }
      .map do |(description, type, reporting_group), grouped|
        DeductionContributionEntry.new(
          description: description,
          type: type,
          reporting_group: reporting_group,
          employee_amount: grouped.sum { |entry| entry.employee_amount.to_f },
          company_amount: grouped.sum { |entry| entry.company_amount.to_f },
          bucket: grouped.first&.bucket,
          source: "aggregate"
        )
      end
      .sort_by { |entry| [ deduction_sort_rank(entry), entry.description.to_s.downcase ] }
  end

  def retirement_rows
    deduction_contribution_entries
      .select { |entry| entry.reporting_group.present? && (entry.employee_amount.to_f.positive? || entry.company_amount.to_f.positive?) }
      .group_by { |entry| [ entry.reporting_group, entry.employee_name ] }
      .map do |(group, employee_name), grouped|
        RetirementRow.new(
          group: group,
          employee_name: employee_name,
          employee_amount: grouped.sum { |entry| entry.employee_amount.to_f },
          company_amount: grouped.sum { |entry| entry.company_amount.to_f }
        )
      end
      .sort_by { |row| [ retirement_group_rank(row.group), row.employee_name.to_s.downcase ] }
  end

  def tax_withholding_detail_rows
    items.map do |item|
      {
        employee_name: qb_employee_name(item.employee),
        fit: item.withholding_tax.to_f,
        social_security: item.social_security_tax.to_f,
        medicare: item.medicare_tax.to_f,
        additional_withholding: item.additional_withholding.to_f,
        total: employee_tax_total(item)
      }
    end
  end

  def paycheck_history_rows(include_voided: false)
    items(include_voided: include_voided).map do |item|
      {
        pay_date: item.check_date || pay_period.pay_date,
        employee_name: qb_employee_name(item.employee),
        total_pay: item.gross_pay.to_f + other_pay_lines_for(item).sum { |line| line.amount.to_f },
        gross_pay: item.gross_pay.to_f,
        net_pay: item.net_pay.to_f,
        pay_method: item.check_number.present? ? "Check" : "No check issued",
        check_number: item.check_number,
        status: item.check_status || "—",
        taxes: employee_tax_total(item),
        deductions: item.total_deductions.to_f,
        employer_cost: total_payroll_cost(item)
      }
    end
  end

  private

  def build_deduction_contribution_entries(item)
    entries = []
    field_entries_by_treatment = {
      "pre_tax" => payroll_field_entries_for(item, "pre_tax_deduction"),
      "post_tax" => payroll_field_entries_for(item, "post_tax_deduction"),
      "employer_contribution" => payroll_field_entries_for(item, "employer_contribution")
    }

    item.payroll_item_deductions.each do |deduction|
      next if legacy_employer_retirement_deduction?(item, deduction)
      next if payroll_field_mirrored_deduction?(deduction, field_entries_by_treatment[deduction.category] || [])

      group = reporting_group_for_deduction(deduction)
      description = group ? PayrollReportingGroups.label(group) : deduction.label
      type = group ? PayrollReportingGroups.type_label(group) : type_label_for_deduction(deduction)

      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: description,
        type: type,
        employee_amount: deduction.employer_contribution? ? 0.0 : deduction.amount.to_f,
        company_amount: deduction.employer_contribution? ? deduction.amount.to_f : 0.0,
        bucket: deduction.category,
        reporting_group: group,
        source: "deduction"
      )
    end

    field_entries_by_treatment.values.flatten.each do |entry|
      next unless entry.amount.to_f.positive?

      group = reporting_group_for_field_entry(entry)
      description = group ? PayrollReportingGroups.label(group) : entry.label
      type = group ? PayrollReportingGroups.type_label(group) : type_label_for_field_entry(entry)
      employee_amount = entry.employer_contribution? ? 0.0 : entry.amount.to_f
      company_amount = entry.employer_contribution? ? entry.amount.to_f : 0.0

      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: description,
        type: type,
        employee_amount: employee_amount,
        company_amount: company_amount,
        bucket: entry.employer_contribution? ? "employer_contribution" : (entry.pre_tax_deduction? ? "pre_tax" : "post_tax"),
        reporting_group: group,
        source: "payroll_field"
      )
    end

    entries.concat(legacy_retirement_entries(item))
    entries.concat(legacy_special_deduction_entries(item))
    entries.concat(custom_deduction_entries(item))

    entries
  end

  def legacy_retirement_entries(item)
    entries = []
    if item.retirement_payment.to_f.positive?
      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: PayrollReportingGroups.label(PayrollReportingGroups::GROUP_401K_PRE_TAX),
        type: PayrollReportingGroups.type_label(PayrollReportingGroups::GROUP_401K_PRE_TAX),
        employee_amount: item.retirement_payment.to_f,
        company_amount: 0.0,
        bucket: "pre_tax",
        reporting_group: PayrollReportingGroups::GROUP_401K_PRE_TAX,
        source: "legacy_retirement"
      )
    end

    if item.roth_retirement_payment.to_f.positive?
      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: PayrollReportingGroups.label(PayrollReportingGroups::GROUP_401K_AFTER_TAX),
        type: PayrollReportingGroups.type_label(PayrollReportingGroups::GROUP_401K_AFTER_TAX),
        employee_amount: item.roth_retirement_payment.to_f,
        company_amount: 0.0,
        bucket: "post_tax",
        reporting_group: PayrollReportingGroups::GROUP_401K_AFTER_TAX,
        source: "legacy_roth_retirement"
      )
    end

    if item.employer_retirement_match.to_f.positive?
      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: PayrollReportingGroups.label(PayrollReportingGroups::GROUP_401K_PRE_TAX),
        type: PayrollReportingGroups.type_label(PayrollReportingGroups::GROUP_401K_PRE_TAX),
        employee_amount: 0.0,
        company_amount: item.employer_retirement_match.to_f,
        bucket: "employer_contribution",
        reporting_group: PayrollReportingGroups::GROUP_401K_PRE_TAX,
        source: "legacy_employer_retirement"
      )
    end

    if item.employer_roth_retirement_match.to_f.positive?
      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: PayrollReportingGroups.label(PayrollReportingGroups::GROUP_401K_AFTER_TAX),
        type: PayrollReportingGroups.type_label(PayrollReportingGroups::GROUP_401K_AFTER_TAX),
        employee_amount: 0.0,
        company_amount: item.employer_roth_retirement_match.to_f,
        bucket: "employer_contribution",
        reporting_group: PayrollReportingGroups::GROUP_401K_AFTER_TAX,
        source: "legacy_employer_roth_retirement"
      )
    end

    entries
  end

  def legacy_special_deduction_entries(item)
    entries = []

    if visible_legacy_loan_payment(item).positive?
      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: "Loan",
        type: "Loan Repayment",
        employee_amount: visible_legacy_loan_payment(item),
        company_amount: 0.0,
        bucket: "post_tax",
        source: "legacy_loan"
      )
    end

    if visible_legacy_insurance_payment(item).positive?
      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: "Health Insurance",
        type: "Medical Insurance - Taxable",
        employee_amount: visible_legacy_insurance_payment(item),
        company_amount: 0.0,
        bucket: "post_tax",
        source: "legacy_insurance"
      )
    end

    if item.tips_paid_out.to_f.positive?
      entries << DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: "Tips Paid Out",
        type: "Other after tax deductions",
        employee_amount: item.tips_paid_out.to_f,
        company_amount: 0.0,
        bucket: "post_tax",
        source: "tips_paid_out"
      )
    end

    entries
  end

  def custom_deduction_entries(item)
    Array(item.custom_deductions).filter_map do |deduction|
      amount = deduction["amount"].to_f
      next unless amount.positive?

      DeductionContributionEntry.new(
        item: item,
        employee_name: qb_employee_name(item.employee),
        description: deduction["label"].presence || "Other Deduction",
        type: "Other after tax deductions",
        employee_amount: amount,
        company_amount: 0.0,
        bucket: "post_tax",
        source: "custom_deduction"
      )
    end
  end

  def payroll_field_entries_for(item, *treatments)
    item.payroll_item_field_entries.select { |entry| entry.active? && treatments.include?(entry.tax_treatment) }
  end

  def payroll_field_mirrored_deduction?(deduction, field_entries)
    return false if field_entries.empty?

    deduction_type_name = deduction.deduction_type&.name.to_s
    return false unless deduction_type_name.match?(/Payroll Field/i)

    field_entries.any? { |entry| entry.label == deduction.label }
  end

  def legacy_employer_retirement_deduction?(item, deduction)
    return false unless deduction.employer_contribution?
    return false unless deduction.deduction_type&.sub_category == "retirement"

    label = deduction.label.to_s
    (label == "401(k) Employer Match" && item.employer_retirement_match.to_f.positive?) ||
      (label == "Roth 401(k) Employer Match" && item.employer_roth_retirement_match.to_f.positive?)
  end

  def reporting_group_for_deduction(deduction)
    PayrollReportingGroups.infer_retirement_group(
      explicit_group: deduction.reporting_group.presence || deduction.deduction_type&.reporting_group,
      label: deduction.label,
      category: deduction.deduction_type&.sub_category,
      deduction_category: deduction.category
    )
  end

  def reporting_group_for_field_entry(entry)
    PayrollReportingGroups.infer_retirement_group(
      explicit_group: entry.reporting_group.presence || entry.payroll_field_definition&.reporting_group,
      label: entry.label,
      category: entry.category,
      tax_treatment: entry.tax_treatment
    )
  end

  def visible_legacy_loan_payment(item)
    return 0.0 if item.payroll_item_deductions.any? { |deduction| deduction.deduction_type&.loan? }

    item.loan_payment.to_f
  end

  def visible_legacy_insurance_payment(item)
    return 0.0 if item.payroll_item_deductions.any? { |deduction| deduction.deduction_type&.sub_category == "insurance" }

    item.insurance_payment.to_f
  end

  def type_label_for_deduction(deduction)
    case deduction.deduction_type&.sub_category
    when "loan"
      "Loan Repayment"
    when "insurance"
      "Medical Insurance - Taxable"
    when "child_support", "garnishment"
      "Child/Spousal Support Order"
    when "rent", "phone", "allotment", "reimbursement", "benefit", "other", nil
      deduction.post_tax? ? "Other after tax deductions" : "Pre-tax deductions"
    else
      deduction.deduction_type&.sub_category.to_s.titleize
    end
  end

  def type_label_for_field_entry(entry)
    group = reporting_group_for_field_entry(entry)
    return PayrollReportingGroups.type_label(group) if group

    case entry.category
    when "loan"
      "Loan Repayment"
    when "insurance"
      "Medical Insurance - Taxable"
    when "child_support", "garnishment"
      "Child/Spousal Support Order"
    when "retirement"
      "Retirement Plan"
    else
      entry.tax_treatment == "pre_tax_deduction" ? "Pre-tax deductions" : "Other after tax deductions"
    end
  end

  def deduction_sort_rank(entry)
    return retirement_group_rank(entry.reporting_group) if entry.reporting_group.present?

    case entry.type
    when /Child\/Spousal/
      20
    when /Loan/
      30
    when /Insurance/
      40
    else
      50
    end
  end

  def retirement_group_rank(group)
    case group
    when PayrollReportingGroups::GROUP_401K_PRE_TAX
      0
    when PayrollReportingGroups::GROUP_401K_AFTER_TAX
      1
    when PayrollReportingGroups::GROUP_RETIREMENT_OTHER
      2
    else
      99
    end
  end

  def employee_sort_key(employee)
    [ employee&.last_name.to_s.downcase, employee&.first_name.to_s.downcase, employee&.id.to_i ]
  end

  def format_date(date)
    date&.strftime("%m/%d/%Y") || "—"
  end

  def format_long_date(date)
    date&.strftime("%b %d, %Y") || "—"
  end
end
