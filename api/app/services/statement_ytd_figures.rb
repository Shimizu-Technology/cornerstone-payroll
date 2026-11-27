# frozen_string_literal: true

# The YTD gross and net a paycheck's statement prints, for staff views that
# list many paychecks (the pay run register, a paycheck, a timecard). It reads
# the same population as PayrollStatementYtdSources (the opening balance dated
# on or before the pay date, then earlier and current paychecks paid after it)
# in a few queries per pay run instead of several per paycheck. Saved YTD snapshots are not used: they
# follow payroll calculation, which counts a different population.
class StatementYtdFigures
  # gross is the stub's gross: imported non-taxable reimbursements print as
  # other pay. The rest are PayrollStatementYtdSources#totals.
  Figures = Data.define(:gross, :net, :withholding_tax, :social_security_tax, :medicare_tax, :additional_withholding)
  FIELDS = PayrollStatementYtdSources::TOTAL_FIELDS

  def initialize
    @figures = {}
  end

  # Loads every paycheck's figures at once; call before the per-item lookups.
  def prime(items)
    items.group_by(&:pay_period).each { |period, group| load_period(period, group) }
    self
  end

  def call(item)
    load_period(item.pay_period, [ item ]) unless @figures.key?(item.id)
    @figures.fetch(item.id)
  end

  private

  def load_period(period, items)
    company = period.company
    pay_date = period.pay_date || Date.current
    employee_ids = items.map(&:employee_id).uniq
    balances = opening_balances(company.id, employee_ids, pay_date)
    prior = prior_rows(company, employee_ids, period, pay_date)

    items.each do |item|
      balance = balances[item.employee_id]
      cutoff = balance&.through_pay_date
      counted = ->(row_pay_date) { cutoff.nil? || row_pay_date > cutoff }
      opening = balance&.ytd_aggregate_totals || {}
      sums = FIELDS.to_h { |key, field| [ key, opening.fetch(field, 0).to_d ] }
      prior.fetch(item.employee_id, []).each do |row|
        next unless counted.call(row[:pay_date])

        FIELDS.each_key { |key| sums[key] += row.fetch(key) }
      end
      if item.payroll_included? && period.correction_status.in?([ nil, "correction" ]) && counted.call(pay_date)
        FIELDS.each { |key, field| sums[key] += item.public_send(field).to_d }
      end
      sums[:gross] -= balance.non_taxable_pay.to_d if balance
      @figures[item.id] = Figures.new(**sums.transform_values { |amount| amount.round(2) })
    end
  end

  # PayrollStatementYtdSources#historical_balance for each employee.
  def opening_balances(company_id, employee_ids, pay_date)
    HistoricalEmployeeYtdBalance.joins(:historical_ytd_bridge)
      .where(company_id: company_id, employee_id: employee_ids, tax_year: pay_date.year, historical_ytd_bridges: { status: "applied" })
      .where("historical_employee_ytd_balances.through_pay_date <= ?", pay_date)
      .order(:employee_id, through_pay_date: :desc, "historical_ytd_bridges.applied_at" => :desc,
        "historical_ytd_bridges.id" => :desc, id: :desc)
      .to_a.group_by(&:employee_id).transform_values(&:first)
  end

  # PayrollStatementYtdSources#items before the current paycheck, per employee.
  def prior_rows(company, employee_ids, period, pay_date)
    periods = PayPeriod.reportable_for_company(company).where(pay_date: Date.new(pay_date.year, 1, 1)..pay_date)
      .where("pay_date < :pay_date OR (pay_date = :pay_date AND id < :period_id)", pay_date: pay_date, period_id: period.id)
    PayrollItem.financially_reportable.reportable.joins(:pay_period)
      .where(company_id: company.id, employee_id: employee_ids, pay_period_id: periods.select(:id))
      .pluck(:id, :employee_id, "pay_periods.pay_date", *FIELDS.values)
      .map { |id, employee_id, row_pay_date, *amounts| { id: id, employee_id: employee_id, pay_date: row_pay_date, **FIELDS.keys.zip(amounts.map(&:to_d)).to_h } }
      .group_by { |row| row[:employee_id] }
  end
end
