# frozen_string_literal: true

# Refresh statement YTD snapshots after a change to earlier payroll or to the
# opening balance: an accounting reversal, a replaced check, an out-of-order
# commit, a pay date correction or an activated historical YTD bridge. Saved
# earnings and withholding on the paychecks are never recalculated. A changed
# snapshot also makes the paycheck's posted employee stub due for a recheck.
class PayrollYtdSnapshotRefresh
  def self.call(pay_period:, employee_ids:)
    date = pay_period.pay_date
    periods = PayPeriod.reportable_committed.where(company_id: pay_period.company_id,
      pay_date: date..Date.new(date.year, 12, 31))
      .where("pay_date > ? OR id >= ?", date, pay_period.id)
    refresh!(PayrollItem.financially_reportable.where(employee_id: employee_ids, pay_period_id: periods.select(:id)))
  end

  # Committed periods paid after this one in its tax year, for an earlier-dated
  # run that commits after them.
  def self.after(pay_period:, employee_ids:)
    date = pay_period.pay_date
    periods = PayPeriod.reportable_committed.where(company_id: pay_period.company_id,
      pay_date: date..Date.new(date.year, 12, 31))
      .where("pay_date > :date OR (pay_date = :date AND id > :id)", date: date, id: pay_period.id)
    refresh!(PayrollItem.financially_reportable.where(employee_id: employee_ids, pay_period_id: periods.select(:id)))
  end

  # Writes only snapshots whose values move: touching an unchanged paycheck
  # would also unprepare its check package and recheck its posted stub.
  def self.refresh!(items)
    items.includes(:employee, :pay_period).find_each do |item|
      period = item.pay_period
      ytd = item.employee.ytd_totals_before(year: period.pay_date.year, pay_date: period.pay_date, pay_period_id: period.id)
      retirement = PayrollRetirementTotals.for_item(item)
      snapshot = {
        ytd_gross: ytd[:gross_pay].to_d + item.gross_pay.to_d,
        ytd_net: ytd[:net_pay].to_d + item.net_pay.to_d,
        ytd_withholding_tax: ytd[:withholding_tax].to_d + item.withholding_tax.to_d,
        ytd_social_security_tax: ytd[:social_security_tax].to_d + item.social_security_tax.to_d,
        ytd_medicare_tax: ytd[:medicare_tax].to_d + item.medicare_tax.to_d,
        ytd_retirement: ytd[:retirement].to_d + retirement[:retirement],
        ytd_roth_retirement: ytd[:roth_retirement].to_d + retirement[:roth_retirement]
      }
      next if snapshot.all? { |column, amount| item.public_send(column)&.to_d&.round(2) == amount.round(2) }

      item.update_columns(**snapshot, updated_at: Time.current)
    end
  end
end
