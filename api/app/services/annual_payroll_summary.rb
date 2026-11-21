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

  # total_payroll_cost split by employee, using exactly the sources
  # period_row counts: native paychecks, locked imported paychecks linked to
  # an employee, and every locked imported adjustment. Adjustments whose
  # imported paycheck has no employee are under by_employee[nil]. Imported
  # paychecks not linked to an employee are left out of the total, as in
  # period_row's excluded_unlinked_*, and reported in :excluded_unlinked.
  #
  # basis: :pay_date (default) counts each paycheck whole in the range that
  # holds its pay date, so the total equals period_row's.
  #
  # basis: :work_period counts the part of each paycheck worked in the range.
  # The same paychecks are eligible (the same reportability scopes); they are
  # chosen because their pay period overlaps the range, however late they
  # were paid, and an adjustment follows its imported paycheck's period. Each
  # amount is split into whole cents per day of the pay period, the leftover
  # cents going to its last days, so any split of a range into months adds
  # up to the range exactly. Each component (pay, employer taxes, employer
  # contributions, and any rest of an imported total) is split the same way
  # and the row total is their sum, so the parts always add up to it.
  def payroll_cost_by_employee(period, basis: :pay_date)
    work_period = basis.to_s == "work_period"
    costs = Hash.new { |hash, key| hash[key] = { pay: 0.to_d, employer_taxes: 0.to_d, employer_contributions: 0.to_d, total: 0.to_d } }
    unified = UnifiedPayrollReporting.new(company_id: company.id, period: period)

    native = work_period ? native_items_worked_in(period) : native_items_for(period).includes(:pay_period)
    native.each do |item|
      cost = native_item_cost(item)
      pay_period = item.pay_period
      add_parts(costs[item.employee_id], period, work_period && [ pay_period.start_date, pay_period.end_date, pay_period.pay_date ],
                pay: cost[:gross_pay] + cost[:non_taxable_pay], employer_taxes: cost[:employer_taxes],
                employer_contributions: cost[:employer_contributions], total: cost[:total])
    end
    paychecks = work_period ? unified.historical_paychecks_worked_in(linked: true) : unified.historical_paychecks
    paychecks.each do |row|
      add_historical_parts(costs[row.employee_id], period, row, work_period && [ row.period_start, row.period_end, row.pay_date ])
    end
    adjustments = work_period ? unified.historical_adjustments_worked_in : unified.historical_adjustments
    adjustments.each do |row|
      paycheck = row.historical_paycheck
      add_historical_parts(costs[paycheck.employee_id], period, row,
                           work_period && [ paycheck.period_start, paycheck.period_end, row.effective_pay_date ])
    end
    costs.reject! { |_employee_id, cost| cost.values.all?(&:zero?) }

    unlinked = work_period ? unified.historical_paychecks_worked_in(linked: false) : unified.unlinked_historical_paychecks
    excluded = unlinked.sum(0.to_d) do |row|
      next row.total_payroll_cost.to_d unless work_period

      cents_in_range(row.total_payroll_cost, row.period_start, row.period_end, row.pay_date, period).to_d / 100
    end
    {
      by_employee: costs,
      total_payroll_cost: costs.values.sum(0.to_d) { |cost| cost[:total] },
      excluded_unlinked: { paycheck_count: unlinked.length, total_payroll_cost: excluded }
    }
  end

  # Native paychecks with the same eligibility as native_items_for, chosen
  # because their pay period overlaps the range. A pay period without a
  # usable date range falls back to its pay date.
  def native_items_worked_in(period)
    eligible_periods = @pay_period_scope.where(company_id: company.id)
                                        .where("(pay_periods.start_date <= :last AND pay_periods.end_date >= :first) OR " \
                                               "((pay_periods.start_date IS NULL OR pay_periods.end_date IS NULL OR " \
                                               "pay_periods.end_date < pay_periods.start_date) AND pay_periods.pay_date BETWEEN :first AND :last)",
                                               first: period.start_date, last: period.end_date)
    PayrollItem.joins(:pay_period)
               .includes(:pay_period, :payroll_item_field_entries, payroll_item_deductions: :deduction_type)
               .financially_reportable.reportable
               .where(company_id: company.id, pay_periods: { id: eligible_periods.select(:id) })
  end

  # Whole cents of an amount that fall in the range when it is spread over
  # the days first..last: each day gets the same cents, and the leftover
  # cents go one each to the last days. Without a usable date range the
  # whole amount goes where the pay date falls.
  def cents_in_range(amount, first, last, pay_date, period)
    cents = (amount.to_d * 100).round(0, :half_up).to_i
    return 0 if cents.zero?
    return (period.range.cover?(pay_date) ? cents : 0) if first.nil? || last.nil? || last < first

    from = [ first, period.start_date ].max
    to = [ last, period.end_date ].min
    return 0 if to < from

    per_day, leftover = cents.abs.divmod((last - first).to_i + 1)
    leftover_from = last - leftover + 1
    leftover_days = leftover.zero? ? 0 : [ (to - [ from, leftover_from ].max).to_i + 1, 0 ].max
    (cents.negative? ? -1 : 1) * ((per_day * ((to - from).to_i + 1)) + leftover_days)
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

  def add_historical_parts(entry, period, row, window)
    add_parts(entry, period, window, pay: row.gross_pay.to_d, employer_taxes: row.employer_taxes.to_d,
              employer_contributions: row.employer_contributions.to_d, total: row.total_payroll_cost.to_d)
  end

  # Adds one paycheck's cost: whole when window is false (pay date basis),
  # otherwise the cents of each component that fall in the range, with the
  # total built from the components plus any rest of the source total.
  def add_parts(entry, period, window, pay:, employer_taxes:, employer_contributions:, total:)
    return add_cost(entry, pay, employer_taxes, employer_contributions, total) unless window

    first, last, pay_date = window
    portion = ->(amount) { cents_in_range(amount, first, last, pay_date, period).to_d / 100 }
    pay_part = portion.call(pay)
    taxes_part = portion.call(employer_taxes)
    contributions_part = portion.call(employer_contributions)
    rest_part = portion.call(total - pay - employer_taxes - employer_contributions)
    add_cost(entry, pay_part, taxes_part, contributions_part, pay_part + taxes_part + contributions_part + rest_part)
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
