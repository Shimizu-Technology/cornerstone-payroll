# frozen_string_literal: true

class AnnualPayrollSummary
  MONEY_FIELDS = %i[
    gross_pay non_taxable_pay adjusted_gross pretax_deductions employee_taxes
    after_tax_deductions net_pay employer_taxes employer_contributions total_payroll_cost
  ].freeze
  TOTAL_FIELDS = ([ :hours ] + MONEY_FIELDS).freeze

  def initialize(company:)
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

  private

  attr_reader :company

  def row_for(year)
    period = PayrollReportingPeriod.new(
      start_date: Date.new(year, 1, 1),
      end_date: Date.new(year, 12, 31),
      year: year
    )
    native_items = native_items_for(period).to_a
    unified = UnifiedPayrollReporting.new(company_id: company.id, period: period)
    imported_paychecks = unified.historical_paychecks
    adjustments = unified.historical_adjustments
    unlinked = unified.unlinked_historical_paychecks
    native = native_totals(native_items)
    imported = unified.historical_financial_totals(imported_paychecks, adjustments)

    {
      year: year,
      payroll_count: native_items.map(&:pay_period_id).uniq.length + regular_historical_period_count(imported_paychecks),
      paycheck_count: native_items.length + imported_paychecks.length,
      employee_count: (native_items.map(&:employee_id) + imported_paychecks.map(&:employee_id)).compact.uniq.length,
      cornerstone_payroll_count: native_items.map(&:pay_period_id).uniq.length,
      cornerstone_paycheck_count: native_items.length,
      quickbooks_payroll_count: regular_historical_period_count(imported_paychecks),
      quickbooks_paycheck_count: imported_paychecks.length,
      opening_summary_count: imported_paychecks.count { |paycheck| paycheck.historical_pay_period.period_type == "opening_summary" },
      adjustment_count: adjustments.length,
      excluded_unlinked_paycheck_count: unlinked.length,
      excluded_unlinked_gross_pay: money(sum(unlinked, :gross_pay)),
      excluded_unlinked_net_pay: money(sum(unlinked, :net_pay)),
      **TOTAL_FIELDS.index_with { |field| field == :hours ? number(native[field] + imported[field], 4) : money(native[field] + imported[field]) }
    }
  end

  def available_years
    years = native_years + historical_years + adjustment_years
    years.compact.map(&:to_i).uniq.sort.reverse
  end

  def native_years
    PayPeriod.reportable_committed.where(company_id: company.id).where.not(pay_date: nil).distinct.pluck(Arel.sql("EXTRACT(YEAR FROM pay_date)::integer"))
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

  def native_items_for(period)
    PayrollItem.joins(:pay_period)
               .includes(:payroll_item_field_entries, payroll_item_deductions: :deduction_type)
               .not_voided
               .where(company_id: company.id, pay_periods: {
                 id: PayPeriod.reportable_committed.where(company_id: company.id, pay_date: period.range).select(:id)
               })
  end

  def native_totals(items)
    totals = TOTAL_FIELDS.index_with { 0.to_d }

    items.each do |item|
      pretax = native_pretax_deductions(item)
      employee_taxes = native_employee_taxes(item)
      after_tax = native_after_tax_deductions(item, pretax:, employee_taxes:)
      non_taxable = native_non_taxable_pay(item)
      employer_taxes = item.employer_social_security_tax.to_d + item.employer_medicare_tax.to_d
      employer_contributions = native_employer_contributions(item)

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
      totals[:total_payroll_cost] += item.gross_pay.to_d + non_taxable + employer_taxes + employer_contributions
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
    return itemized unless item.loan_deduction.to_d.positive?

    itemized_loans = deductions.select { |deduction| deduction.post_tax? && deduction.deduction_type&.loan? }
                               .sum(0.to_d) { |deduction| deduction.amount.to_d }
    itemized - itemized_loans + item.loan_deduction.to_d
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
                            .not_voided
                            .where(company_id: company.id, pay_periods: {
                              id: PayPeriod.reportable_committed.where(company_id: company.id).where.not(pay_date: nil).select(:id)
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
