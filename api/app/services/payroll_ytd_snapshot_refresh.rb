# frozen_string_literal: true

# Refresh statement YTD snapshots after an accounting reversal. Saved earnings
# and withholding on subsequent paychecks are never recalculated.
class PayrollYtdSnapshotRefresh
  def self.call(pay_period:, employee_ids:)
    date = pay_period.pay_date
    periods = PayPeriod.reportable_committed.where(company_id: pay_period.company_id,
      pay_date: date..Date.new(date.year, 12, 31))
      .where("pay_date > ? OR id >= ?", date, pay_period.id)
    PayrollItem.financially_reportable.where(employee_id: employee_ids, pay_period_id: periods.select(:id))
      .includes(:employee, :pay_period).find_each do |item|
      period = item.pay_period
      ytd = item.employee.ytd_totals_before(year: date.year, pay_date: period.pay_date, pay_period_id: period.id)
      retirement = PayrollRetirementTotals.for_item(item)
      item.update_columns(
        ytd_gross: ytd[:gross_pay].to_d + item.gross_pay.to_d,
        ytd_net: ytd[:net_pay].to_d + item.net_pay.to_d,
        ytd_withholding_tax: ytd[:withholding_tax].to_d + item.withholding_tax.to_d,
        ytd_social_security_tax: ytd[:social_security_tax].to_d + item.social_security_tax.to_d,
        ytd_medicare_tax: ytd[:medicare_tax].to_d + item.medicare_tax.to_d,
        ytd_retirement: ytd[:retirement].to_d + retirement[:retirement],
        ytd_roth_retirement: ytd[:roth_retirement].to_d + retirement[:roth_retirement],
        updated_at: Time.current
      )
    end
  end
end
