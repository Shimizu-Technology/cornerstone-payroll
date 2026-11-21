# frozen_string_literal: true

class AnnualPayrollSummary
  MONEY_FIELDS = %i[
    gross_pay non_taxable_pay adjusted_gross pretax_deductions employee_taxes
    after_tax_deductions net_pay employer_taxes employer_contributions total_payroll_cost
  ].freeze
  TOTAL_FIELDS = ([ :hours ] + MONEY_FIELDS).freeze

  def initialize(company:, pay_period_scope: PayPeriod.reportable_committed)
    @pay_period_scope = pay_period_scope
    @company = company
  end

  def call
    rows = available_years.map { |year| row_for(year) }

    {
      type: "annual_payroll_summary",
      meta: {
        company_id: company.id,
        company_name: company.name,
        generated_at: Time.current.iso8601,
        period_basis: "pay_date"
      },
      source_statement: UnifiedPayrollReporting::SOURCE_STATEMENT,
      years: rows,
      totals: overall_totals(rows)
    }
  end

  # Paychecks counted for a period (by pay date). Also used by
  # ClientProfitability::Report so the two reports count the same checks.
  def native_items_for(period)
    PayrollItem.joins(:pay_period)
               .includes(:payroll_item_field_entries, payroll_item_deductions: :deduction_type)
               .financially_reportable.reportable
               .where(company_id: company.id, pay_periods: {
                 id: @pay_period_scope.where(company_id: company.id, pay_date: period.range).select(:id)
               })
  end

  # What one paycheck cost the employer, as counted in total_payroll_cost:
  # gross pay, non-taxable pay, employer taxes and employer contributions.
  def native_item_cost(item)
    non_taxable = native_non_taxable_pay(item)
    employer_taxes = item.employer_social_security_tax.to_d + item.employer_medicare_tax.to_d
    employer_contributions = native_employer_contributions(item)
    {
      gross_pay: item.gross_pay.to_d,
      non_taxable_pay: non_taxable,
      employer_taxes: employer_taxes,
      employer_contributions: employer_contributions,
      total: item.gross_pay.to_d + non_taxable + employer_taxes + employer_contributions
    }
  end

  # How far outside the range a paycheck's pay date may fall and still have
  # worked days inside it (basis: :work_period).
  WORK_PERIOD_REACH = 120

  # total_payroll_cost split by employee, using exactly the sources
  # period_row counts: native paychecks, locked imported paychecks linked to
  # an employee, and every locked imported adjustment. Adjustments whose
  # imported paycheck has no employee are under by_employee[nil]. Imported
  # paychecks not linked to an employee are left out of the total, as in
  # period_row's excluded_unlinked_*, and reported in :excluded_unlinked.
  #
  # basis: :pay_date (default) counts each paycheck whole in the range that
  # holds its pay date, so the total equals period_row's. basis:
  # :work_period spreads each paycheck evenly over the days of its pay
  # period (an adjustment follows its imported paycheck's period) and counts
  # the days that fall in the range; the same paychecks are eligible, found
  # by pay date up to WORK_PERIOD_REACH days either side.
  def payroll_cost_by_employee(period, basis: :pay_date)
    work_period = basis.to_s == "work_period"
    source = if work_period
      PayrollReportingPeriod.new(start_date: period.start_date - WORK_PERIOD_REACH, end_date: period.end_date + WORK_PERIOD_REACH)
    else
      period
    end
    share = ->(first, last, pay_date) { work_period ? work_period_share(first, last, pay_date, period) : 1.to_d }

    costs = Hash.new { |hash, key| hash[key] = { pay: 0.to_d, employer_taxes: 0.to_d, employer_contributions: 0.to_d, total: 0.to_d } }
    native_items_for(source).includes(:pay_period).each do |item|
      fraction = share.call(item.pay_period.start_date, item.pay_period.end_date, item.pay_period.pay_date)
      next if fraction.zero?

      cost = native_item_cost(item)
      add_cost(costs[item.employee_id], (cost[:gross_pay] + cost[:non_taxable_pay]) * fraction, cost[:employer_taxes] * fraction,
               cost[:employer_contributions] * fraction, cost[:total] * fraction)
    end
    unified = UnifiedPayrollReporting.new(company_id: company.id, period: source)
    unified.historical_paychecks.each do |row|
      add_historical_cost(costs[row.employee_id], row, share.call(row.period_start, row.period_end, row.pay_date))
    end
    unified.historical_adjustments.each do |row|
      paycheck = row.historical_paycheck
      add_historical_cost(costs[paycheck.employee_id], row, share.call(paycheck.period_start, paycheck.period_end, row.effective_pay_date))
    end
    costs.each_value { |cost| cost.transform_values! { |value| value.round(2, :half_up) } }
    costs.reject! { |_employee_id, cost| cost.values.all?(&:zero?) }
    unlinked = unified.unlinked_historical_paychecks.filter_map do |row|
      fraction = share.call(row.period_start, row.period_end, row.pay_date)
      row.total_payroll_cost.to_d * fraction unless fraction.zero?
    end
    {
      by_employee: costs,
      total_payroll_cost: costs.values.sum(0.to_d) { |cost| cost[:total] },
      excluded_unlinked: { paycheck_count: unlinked.length, total_payroll_cost: unlinked.sum(0.to_d).round(2, :half_up) }
    }
  end

  # The same summary row as a year's, for any pay-date range.
  def period_row(period)
    native_items = native_items_for(period).to_a
    unified = UnifiedPayrollReporting.new(company_id: company.id, period: period)
    imported_paychecks = unified.historical_paychecks
    adjustments = unified.historical_adjustments
    unlinked = unified.unlinked_historical_paychecks
    native = native_totals(native_items)
    imported = unified.historical_financial_totals(imported_paychecks, adjustments)

    {
      payroll_count: native_items.map(&:pay_period_id).uniq.length + regular_historical_period_count(imported_paychecks),
      paycheck_count: native_items.length + regular_historical_paycheck_count(imported_paychecks),
      employee_count: (native_items.map(&:employee_id) + imported_paychecks.map(&:employee_id)).compact.uniq.length,
      cornerstone_payroll_count: native_items.map(&:pay_period_id).uniq.length,
      cornerstone_paycheck_count: native_items.length,
      quickbooks_payroll_count: regular_historical_period_count(imported_paychecks),
      quickbooks_paycheck_count: regular_historical_paycheck_count(imported_paychecks),
      quickbooks_record_count: imported_paychecks.length,
      opening_summary_count: imported_paychecks.count { |paycheck| paycheck.historical_pay_period.period_type == "opening_summary" },
      adjustment_count: adjustments.length,
      excluded_unlinked_paycheck_count: unlinked.length,
      excluded_unlinked_gross_pay: money(sum(unlinked, :gross_pay)),
      excluded_unlinked_net_pay: money(sum(unlinked, :net_pay)),
      **TOTAL_FIELDS.index_with { |field| field == :hours ? number(native[field] + imported[field], 4) : money(native[field] + imported[field]) }
    }
  end

  private

  def add_historical_cost(entry, row, fraction = 1.to_d)
    return if fraction.zero?

    add_cost(entry, row.gross_pay.to_d * fraction, row.employer_taxes.to_d * fraction, row.employer_contributions.to_d * fraction,
             row.total_payroll_cost.to_d * fraction)
  end

  # The part of a pay period's days that fall inside the range. Without a
  # usable pay period, the whole paycheck goes where its pay date falls.
  def work_period_share(first, last, pay_date, period)
    return (period.range.cover?(pay_date) ? 1.to_d : 0.to_d) if first.nil? || last.nil? || last < first

    overlap = ([ last, period.end_date ].min - [ first, period.start_date ].max).to_i + 1
    return 0.to_d unless overlap.positive?

    overlap.to_d / ((last - first).to_i + 1)
  end

  def add_cost(entry, pay, employer_taxes, employer_contributions, total)
    entry[:pay] += pay
    entry[:employer_taxes] += employer_taxes
    entry[:employer_contributions] += employer_contributions
    entry[:total] += total
  end

  attr_reader :company

  def row_for(year)
    period = PayrollReportingPeriod.new(
      start_date: Date.new(year, 1, 1),
      end_date: Date.new(year, 12, 31),
      year: year
    )
    { year: year }.merge(period_row(period))
  end

  def available_years
    years = native_years + historical_years + adjustment_years
    years.compact.map(&:to_i).uniq.sort.reverse
  end

  def native_years
    @pay_period_scope.where(company_id: company.id).where.not(pay_date: nil).distinct.pluck(Arel.sql("EXTRACT(YEAR FROM pay_date)::integer"))
  end

  def historical_years
    HistoricalPaycheck.joins(:historical_import_batch)
                       .where(company_id: company.id, historical_import_batches: { company_id: company.id, status: "locked" })
                       .distinct
                       .pluck(Arel.sql("EXTRACT(YEAR FROM pay_date)::integer"))
  end

  def adjustment_years
    HistoricalPaycheckAdjustment.joins(historical_paycheck: :historical_import_batch)
                                 .where(company_id: company.id, historical_import_batches: { company_id: company.id, status: "locked" })
                                 .distinct
                                 .pluck(Arel.sql("EXTRACT(YEAR FROM effective_pay_date)::integer"))
  end

  def native_totals(items)
    totals = TOTAL_FIELDS.index_with { 0.to_d }

    items.each do |item|
      pretax = native_pretax_deductions(item)
      employee_taxes = native_employee_taxes(item)
      after_tax = native_after_tax_deductions(item, pretax:, employee_taxes:)
      cost = native_item_cost(item)
      non_taxable = cost[:non_taxable_pay]
      employer_taxes = cost[:employer_taxes]
      employer_contributions = cost[:employer_contributions]

      totals[:hours] += item.total_hours.to_d
      totals[:gross_pay] += item.gross_pay.to_d
      totals[:non_taxable_pay] += non_taxable
      totals[:adjusted_gross] += item.gross_pay.to_d - pretax
      totals[:pretax_deductions] += pretax
      totals[:employee_taxes] += employee_taxes
      totals[:after_tax_deductions] += after_tax
      totals[:net_pay] += item.net_pay.to_d
      totals[:employer_taxes] += employer_taxes
      totals[:employer_contributions] += employer_contributions
      totals[:total_payroll_cost] += cost[:total]
    end

    totals
  end

  def native_pretax_deductions(item)
    item.retirement_payment.to_d +
      deduction_total(item, "pre_tax") +
      item.pre_tax_payroll_adjustments_total.to_d
  end

  def native_employee_taxes(item)
    item.withholding_tax.to_d + item.additional_withholding.to_d + item.social_security_tax.to_d +
      item.medicare_tax.to_d
  end

  def native_after_tax_deductions(item, pretax:, employee_taxes:)
    if item.correction_entry?
      return item.total_deductions.to_d - pretax - employee_taxes
    end

    item.roth_retirement_payment.to_d + native_itemized_or_legacy_post_tax(item) +
      item.custom_deductions_total.to_d + item.post_tax_payroll_adjustments_total.to_d + item.tips_paid_out.to_d
  end

  def native_itemized_or_legacy_post_tax(item)
    deductions = item.payroll_item_deductions
    return item.loan_payment.to_d + item.insurance_payment.to_d if deductions.empty?

    itemized = deductions.select(&:post_tax?).sum(0.to_d) { |deduction| deduction.amount.to_d }
    itemized + item.loan_deduction.to_d
  end

  def native_non_taxable_pay(item)
    if item.correction_entry?
      return item.net_pay.to_d - item.gross_pay.to_d + item.total_deductions.to_d
    end

    item.non_taxable_pay.to_d + item.non_taxable_payroll_adjustments_total.to_d + item.non_taxable_payroll_field_entries_total.to_d
  end

  def native_employer_contributions(item)
    itemized = deduction_total(item, "employer_contribution")
    return itemized if itemized.nonzero?

    item.employer_retirement_match.to_d + item.employer_roth_retirement_match.to_d
  end

  def deduction_total(item, category)
    item.payroll_item_deductions.select { |deduction| deduction.category == category }
        .sum(0.to_d) { |deduction| deduction.amount.to_d }
  end

  def regular_historical_period_count(paychecks)
    paychecks.filter_map do |paycheck|
      paycheck.historical_pay_period_id if paycheck.historical_pay_period.period_type == "regular"
    end.uniq.length
  end

  def regular_historical_paycheck_count(paychecks)
    paychecks.count { |paycheck| paycheck.historical_pay_period.period_type == "regular" }
  end

  def overall_totals(rows)
    totals = {
      year_count: rows.length,
      payroll_count: rows.sum { |row| row[:payroll_count] },
      paycheck_count: rows.sum { |row| row[:paycheck_count] },
      employee_count: overall_employee_count,
      cornerstone_payroll_count: rows.sum { |row| row[:cornerstone_payroll_count] },
      cornerstone_paycheck_count: rows.sum { |row| row[:cornerstone_paycheck_count] },
      quickbooks_payroll_count: rows.sum { |row| row[:quickbooks_payroll_count] },
      quickbooks_paycheck_count: rows.sum { |row| row[:quickbooks_paycheck_count] },
      quickbooks_record_count: rows.sum { |row| row[:quickbooks_record_count] },
      opening_summary_count: rows.sum { |row| row[:opening_summary_count] },
      adjustment_count: rows.sum { |row| row[:adjustment_count] },
      excluded_unlinked_paycheck_count: rows.sum { |row| row[:excluded_unlinked_paycheck_count] },
      excluded_unlinked_gross_pay: money(rows.sum(0.to_d) { |row| row[:excluded_unlinked_gross_pay].to_d }),
      excluded_unlinked_net_pay: money(rows.sum(0.to_d) { |row| row[:excluded_unlinked_net_pay].to_d })
    }
    TOTAL_FIELDS.each do |field|
      value = rows.sum(0.to_d) { |row| row[field].to_d }
      totals[field] = field == :hours ? number(value, 4) : money(value)
    end
    totals
  end

  def overall_employee_count
    native_ids = PayrollItem.joins(:pay_period)
                            .financially_reportable.reportable
                            .where(company_id: company.id, pay_periods: {
                              id: @pay_period_scope.where(company_id: company.id).where.not(pay_date: nil).select(:id)
                            })
                            .distinct
                            .pluck(:employee_id)
    historical_ids = HistoricalPaycheck.joins(:historical_import_batch)
                                        .where(company_id: company.id, historical_import_batches: { company_id: company.id, status: "locked" })
                                        .where.not(employee_id: nil)
                                        .where.not(pay_date: nil)
                                        .distinct
                                        .pluck(:employee_id)
    (native_ids + historical_ids).uniq.length
  end

  def sum(rows, field)
    rows.sum(0.to_d) { |row| row.public_send(field).to_d }
  end

  def money(value)
    value.to_d.round(2).to_f
  end

  def number(value, precision)
    value.to_d.round(precision).to_f
  end
end
