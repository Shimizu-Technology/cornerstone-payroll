# frozen_string_literal: true

# Employee 401(k) contributions from the saved paycheck components. Reports
# already reconcile flexible fields with their itemized deduction mirrors.
# Reuse that reconciliation so a contribution appears in YTD exactly once.
class PayrollRetirementTotals
  GROUP_KEYS = {
    PayrollReportingGroups::GROUP_401K_PRE_TAX => :retirement,
    PayrollReportingGroups::GROUP_401K_AFTER_TAX => :roth_retirement
  }.freeze
  BUILT_IN_SOURCES = %w[legacy_retirement legacy_roth_retirement].freeze

  def self.for_item(item)
    totals = {
      retirement: item.retirement_payment.to_d,
      roth_retirement: item.roth_retirement_payment.to_d
    }
    QuickbooksPayrollReportData.new(item.pay_period).deduction_contribution_entries_for_item(item).each do |entry|
      next if BUILT_IN_SOURCES.include?(entry.source)

      key = GROUP_KEYS[entry.reporting_group]
      totals[key] += entry.employee_amount.to_d if key
    end
    totals.transform_values { |amount| amount.round(2) }
  end

  def self.retirement_field?(entry)
    group = PayrollReportingGroups.infer_retirement_group(
      explicit_group: entry.reporting_group.presence || entry.payroll_field_definition&.reporting_group,
      label: entry.label, category: entry.category, tax_treatment: entry.tax_treatment
    )
    GROUP_KEYS.key?(group)
  end

  def self.retirement_deduction?(deduction)
    group = PayrollReportingGroups.infer_retirement_group(
      explicit_group: deduction.reporting_group.presence || deduction.deduction_type&.reporting_group,
      label: deduction.label, category: deduction.deduction_type&.sub_category, deduction_category: deduction.category
    )
    GROUP_KEYS.key?(group)
  end

  def self.for_scope(scope)
    for_scope_by_employee(scope).values.each_with_object({ retirement: 0.to_d, roth_retirement: 0.to_d }) do |values, totals|
      totals.each_key { |key| totals[key] += values.fetch(key) }
    end
  end

  def self.for_scope_by_employee(scope)
    totals = {}
    scope.includes(:employee, { pay_period: :company }, { payroll_item_field_entries: :payroll_field_definition },
                   payroll_item_deductions: :deduction_type).find_each do |item|
      employee_totals = totals[item.employee_id] ||= { retirement: 0.to_d, roth_retirement: 0.to_d }
      for_item(item).each { |key, value| employee_totals[key] += value }
    end
    totals
  end
end
