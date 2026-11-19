# frozen_string_literal: true

# Year-end only: never recalculate a paid paycheck or reuse today's employee setup.
class W2GuTaxableWages
  RETIREMENT_401K_GROUPS = [ PayrollReportingGroups::GROUP_401K_PRE_TAX, PayrollReportingGroups::GROUP_401K_AFTER_TAX,
    PayrollReportingGroups::GROUP_401K_NON_ROTH_AFTER_TAX ].freeze
  # Only positively identified cafeteria-plan benefits are FICA-exempt. Other
  # pre-tax items (457(b), other retirement deferrals, unlabeled adjustments)
  # reduce Box 1 only.
  FICA_EXEMPT_TYPE = "Medical Insurance - Taxable" # QuickbooksPayrollReportData's label for the insurance category
  FICA_EXEMPT_LABEL = /\bsection\s*125\b|\bcafeteria\b|\b(?:health|medical|dental|vision)\b/i

  def self.fica_exempt?(entry)
    return false if entry.reporting_group.present?

    entry.type == FICA_EXEMPT_TYPE || entry.description.to_s.match?(FICA_EXEMPT_LABEL)
  end

  def self.for_item(item)
    entries = QuickbooksPayrollReportData.new(item.pay_period, for_reporting: true).deduction_contribution_entries_for_item(item)
    pretax = entries.select { |entry| entry.bucket == "pre_tax" && !RETIREMENT_401K_GROUPS.include?(entry.reporting_group) }
    retirement = PayrollRetirementTotals.for_item(item, for_reporting: true).fetch(:retirement)
    other_pretax = pretax.sum(0.to_d) { |entry| entry.employee_amount.to_d }
    benefits = pretax.select { |entry| fica_exempt?(entry) }.sum(0.to_d) { |entry| entry.employee_amount.to_d }

    # Live gross excludes reimbursements (calculate_net_pay adds them separately).
    # QuickBooks inclusive gross is handled by the historical bridge, not here.
    fit = (item.gross_pay.to_d - retirement - other_pretax).round(2)
    medicare = (item.gross_pay.to_d - benefits).round(2)
    tips = (item.cash_tips_reported || item.reported_tips).to_d
    wages = item.gross_pay.to_d - tips
    wages = [ wages, 0.to_d ].max unless item.gross_pay.to_d.negative?
    # The payroll engine feeds unreduced gross into FICA. When benefits exist,
    # rebuild uncapped wages and let W2GuAggregator apply the annual wage base.
    # Otherwise retain committed FICA allocations, including signed corrections.
    uncapped_wages = wages - benefits
    uncapped_tips = tips
    if item.gross_pay.to_d >= 0 && benefits >= 0
      uncapped_wages = [ uncapped_wages, 0.to_d ].max
      uncapped_tips = [ tips, [ medicare, 0.to_d ].max ].min
    end
    # The paycheck withheld FICA on these benefits; W-2 Boxes 3/5 then disagree
    # with Boxes 4/6 and the 941s until payroll is corrected (refund + 941-X).
    fica_on_benefits = benefits.positive? && item.medicare_taxable_wages.present? && item.medicare_taxable_wages.to_d > medicare
    ss_wages = benefits.nonzero? ? uncapped_wages : (item.social_security_taxable_wages || wages)
    ss_tips = benefits.nonzero? ? uncapped_tips : (item.social_security_taxable_tips || tips)
    {
      box1: item.fit_taxable_wages == fit ? item.fit_taxable_wages.to_d : fit,
      ss_wages: ss_wages.to_d,
      uncapped_ss_wages: uncapped_wages,
      uncapped_ss_tips: uncapped_tips,
      benefit_item_count: benefits.nonzero? ? 1 : 0,
      fica_on_benefits_count: fica_on_benefits ? 1 : 0,
      ss_tips: ss_tips.to_d,
      medicare: item.medicare_taxable_wages == medicare ? item.medicare_taxable_wages.to_d : medicare,
      inconsistent_fit_count: item.fit_taxable_wages.present? && item.fit_taxable_wages != fit ? 1 : 0
    }
  end
end
