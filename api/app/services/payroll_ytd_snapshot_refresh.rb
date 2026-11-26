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

  SNAPSHOT_FIELDS = {
    ytd_gross: :gross_pay, ytd_net: :net_pay, ytd_withholding_tax: :withholding_tax,
    ytd_social_security_tax: :social_security_tax, ytd_medicare_tax: :medicare_tax,
    ytd_retirement: :retirement, ytd_roth_retirement: :roth_retirement
  }.freeze

  # Writes only snapshots whose values move: touching an unchanged paycheck
  # would also unprepare its check package. Every refreshed paycheck's posted
  # employee stub becomes due for a recheck either way, since an earlier
  # change can move a YTD row it prints without moving these totals; the
  # recheck revises the stub only when a printed amount changed.
  #
  # Each employee's year loads once, so every paycheck adds up the same
  # earlier paychecks Employee#ytd_totals_before would, without a query each.
  def self.refresh!(items)
    targets = items.includes(:employee, :pay_period).to_a
    targets.group_by { |item| [ item.employee_id, item.pay_period.pay_date.year ] }.each_value do |group|
      year = EmployeeYear.new(group.first.employee, group.first.pay_period.pay_date.year, through: group.map { |item| item.pay_period.pay_date }.max)
      group.each do |item|
        before = year.totals_before(item)
        own = year.amounts(item)
        snapshot = SNAPSHOT_FIELDS.to_h { |column, field| [ column, before.fetch(field) + own.fetch(field) ] }
        next if snapshot.all? { |column, amount| item.public_send(column)&.to_d&.round(2) == amount.round(2) }

        item.update_columns(**snapshot, updated_at: Time.current)
      end
    end
    mark_stubs_due!(targets.map(&:id))
  end

  # The posting job rechecks a posted stub whose last check is missing.
  def self.mark_stubs_due!(item_ids)
    return if item_ids.empty?

    EmployeeDocument.posted.where(payroll_item_id: item_ids).where.not(payroll_facts_checked_at: nil)
      .update_all(payroll_facts_checked_at: nil, updated_at: Time.current)
  end

  # One employee's financially reportable payroll for a tax year, through a
  # pay date, and the applied opening balance, as Employee#ytd_totals_before
  # counts them for payroll calculation.
  class EmployeeYear
    def initialize(employee, year, through:)
      @employee = employee
      @year = year
      periods = PayPeriod.reportable_for_company(employee.company).where(pay_date: Date.new(year, 1, 1)..through)
      @items = employee.payroll_items.financially_reportable.where(pay_period_id: periods.select(:id))
        .includes({ pay_period: :company }, { payroll_item_field_entries: :payroll_field_definition },
                  payroll_item_deductions: :deduction_type).to_a
      @items.each { |item| item.association(:employee).target = employee }
      zero = SNAPSHOT_FIELDS.values.index_with(0.0)
      @opening = employee.merge_historical_ytd(zero, year).transform_values(&:to_d)
      @amounts = {}
    end

    def totals_before(item)
      period = item.pay_period
      earlier = @items.select do |other|
        other.pay_period.pay_date < period.pay_date || (other.pay_period.pay_date == period.pay_date && other.pay_period_id < period.id)
      end
      SNAPSHOT_FIELDS.values.to_h do |field|
        [ field, @opening.fetch(field) + earlier.sum(0.to_d) { |other| amounts(other).fetch(field) } ]
      end
    end

    def amounts(item)
      @amounts[item.id] ||= begin
        retirement = retirement_for(item)
        {
          gross_pay: item.gross_pay.to_d, net_pay: item.net_pay.to_d, withholding_tax: item.withholding_tax.to_d,
          social_security_tax: item.social_security_tax.to_d, medicare_tax: item.medicare_tax.to_d,
          retirement: retirement.fetch(:retirement), roth_retirement: retirement.fetch(:roth_retirement)
        }
      end
    end

    private

    # A paycheck whose saved field mirrors cannot be attributed keeps its
    # saved 401(k) amounts in the snapshot. The correction and posting paths
    # still stop on that history; a staff snapshot does not.
    def retirement_for(item)
      PayrollRetirementTotals.for_item(@items.find { |loaded| loaded.id == item.id } || item)
    rescue PayrollComponentMirrors::AmbiguousHistoryError, PayrollInsuranceComponents::AmbiguousHistoryError
      { retirement: item.retirement_payment.to_d, roth_retirement: item.roth_retirement_payment.to_d }
    end
  end
end
