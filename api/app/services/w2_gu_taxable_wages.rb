# frozen_string_literal: true

# Year-end only: never recalculate a paid paycheck or reuse today's employee setup.
class W2GuTaxableWages
  def self.for_item(item)
    entries = QuickbooksPayrollReportData.new(item.pay_period, for_reporting: true).deduction_contribution_entries_for_item(item)
    pretax = entries.select { |entry| entry.bucket == "pre_tax" }
    retirement = PayrollRetirementTotals.for_item(item, for_reporting: true).fetch(:retirement)
    benefits = pretax.sum(0.to_d) do |entry|
      [ PayrollReportingGroups::GROUP_401K_PRE_TAX, PayrollReportingGroups::GROUP_401K_AFTER_TAX,
        PayrollReportingGroups::GROUP_401K_NON_ROTH_AFTER_TAX ].include?(entry.reporting_group) ? 0.to_d : entry.employee_amount.to_d
    end

    # Live gross excludes reimbursements (calculate_net_pay adds them separately).
    # QuickBooks inclusive gross is handled by the historical bridge, not here.
    fit = (item.gross_pay.to_d - retirement - benefits).round(2)
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
    ss_wages = benefits.nonzero? ? uncapped_wages : (item.social_security_taxable_wages || wages)
    ss_tips = benefits.nonzero? ? uncapped_tips : (item.social_security_taxable_tips || tips)
    {
      box1: item.fit_taxable_wages == fit ? item.fit_taxable_wages.to_d : fit,
      ss_wages: ss_wages.to_d,
      uncapped_ss_wages: uncapped_wages,
      uncapped_ss_tips: uncapped_tips,
      benefit_item_count: benefits.nonzero? ? 1 : 0,
      ss_tips: ss_tips.to_d,
      medicare: item.medicare_taxable_wages == medicare ? item.medicare_taxable_wages.to_d : medicare,
      inconsistent_fit_count: item.fit_taxable_wages.present? && item.fit_taxable_wages != fit ? 1 : 0
    }
  end
end
