# frozen_string_literal: true

class HistoricalEmployeeYtdBalance < ApplicationRecord
  belongs_to :historical_ytd_bridge
  belongs_to :company
  belongs_to :employee

  validates :tax_year, inclusion: { in: 2000..2200 }
  validates :through_pay_date, :through_period_end, presence: true
  validates :employee_id, uniqueness: { scope: %i[historical_ytd_bridge_id tax_year] }
  validate :tenant_matches_bridge_and_employee
  validate :dates_do_not_exceed_bridge_boundary

  before_update :prevent_change
  before_destroy :prevent_change

  # Older bridge plans copied Pay Tip earnings into tips_paid_out without a
  # separate payout in the QuickBooks source. Correct that derived display/YTD
  # value at read time while preserving the immutable source and bridge rows.
  def verified_tips_paid_out
    tip_earnings = source_breakdown.to_h.fetch("earnings_breakdown", {}).to_h.any? do |label, _amount|
      label.match?(QuickbooksHistory::YtdBridgePlan::TIPS)
    end
    return tips_paid_out unless tip_earnings && tips_paid_out.to_d == reported_tips.to_d

    source_breakdown.to_h.fetch("after_tax_deduction_breakdown", {}).to_h.sum(0.to_d) do |label, amount|
      label.match?(QuickbooksHistory::YtdBridgePlan::TIP_PAYOUT) ? amount.to_d : 0.to_d
    end.round(2)
  end

  def ytd_aggregate_totals
    {
      gross_pay: gross_pay,
      net_pay: net_pay,
      withholding_tax: federal_income_tax,
      social_security_tax: social_security_tax,
      medicare_tax: medicare_tax,
      additional_withholding: additional_withholding,
      retirement: retirement,
      roth_retirement: roth_retirement,
      insurance: insurance,
      loans: loans,
      tips_paid_out: verified_tips_paid_out,
      social_security_taxable_total: social_security_taxable_wages + social_security_taxable_tips,
      medicare_taxable_wages: medicare_taxable_wages
    }
  end

  private

  def tenant_matches_bridge_and_employee
    errors.add(:company, "must match the historical YTD bridge") if historical_ytd_bridge && historical_ytd_bridge.company_id != company_id
    errors.add(:employee, "must belong to the same client") if employee && employee.company_id != company_id
  end

  def dates_do_not_exceed_bridge_boundary
    return unless historical_ytd_bridge && through_pay_date && through_period_end

    summary = historical_ytd_bridge.preview_summary.to_h
    bridge_pay_date = Date.iso8601(summary.fetch("through_pay_date").to_s)
    bridge_period_end = Date.iso8601(summary.fetch("through_period_end").to_s)
    errors.add(:through_pay_date, "must be in the balance tax year") if through_pay_date.year != tax_year
    errors.add(:through_pay_date, "cannot exceed the historical YTD bridge boundary") if through_pay_date > bridge_pay_date
    errors.add(:through_period_end, "cannot exceed the historical YTD bridge boundary") if through_period_end > bridge_period_end
  rescue Date::Error, KeyError
    errors.add(:base, "Historical YTD bridge boundary is invalid")
  end

  def prevent_change
    errors.add(:base, "Historical employee YTD balances are immutable")
    throw(:abort)
  end
end
