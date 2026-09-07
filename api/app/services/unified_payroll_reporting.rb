# frozen_string_literal: true

class UnifiedPayrollReporting
  SOURCE_STATEMENT = "QuickBooks values are authoritative locked snapshots and were not recalculated by Cornerstone Payroll."

  def initialize(company_id:, period:)
    @company_id = Integer(company_id)
    @period = period
  end

  def historical_paychecks(employee_id: nil, limit: nil)
    scope = linked_historical_scope
    scope = scope.where(employee_id: employee_id) if employee_id
    scope = scope.reverse_chronological
    scope = scope.limit(limit) if limit
    scope.to_a
  end

  def unlinked_historical_paychecks
    historical_scope.where(employee_id: nil).to_a
  end

  def add_historical_to_employee_row(row, paychecks)
    totals = historical_totals(paychecks)
    row.merge(
      payroll_count: row.fetch(:payroll_count, 0).to_i + regular_period_count(paychecks),
      imported_payroll_count: regular_period_count(paychecks),
      imported_opening_summary_count: opening_summary_count(paychecks),
      gross_pay: row.fetch(:gross_pay, 0).to_f + totals[:gross_pay],
      withholding_tax: row.fetch(:withholding_tax, 0).to_f + totals[:withholding_tax],
      social_security_tax: row.fetch(:social_security_tax, 0).to_f + totals[:social_security_tax],
      medicare_tax: row.fetch(:medicare_tax, 0).to_f + totals[:medicare_tax],
      retirement: row.fetch(:retirement, 0).to_f + totals[:retirement],
      roth_retirement: row.fetch(:roth_retirement, 0).to_f + totals[:roth_retirement],
      tips: row.fetch(:tips, 0).to_f + totals[:tips],
      tips_paid_out: row.fetch(:tips_paid_out, 0).to_f + totals[:tips_paid_out],
      total_deductions: row.fetch(:total_deductions, 0).to_f + totals[:total_deductions],
      net_pay: row.fetch(:net_pay, 0).to_f + totals[:net_pay]
    )
  end

  def add_historical_to_company_totals(row, paychecks, native_employee_ids:)
    totals = historical_totals(paychecks)
    row.merge(
      gross_pay: row.fetch(:gross_pay, 0).to_f + totals[:gross_pay],
      withholding_tax: row.fetch(:withholding_tax, 0).to_f + totals[:withholding_tax],
      social_security_tax: row.fetch(:social_security_tax, 0).to_f + totals[:social_security_tax],
      medicare_tax: row.fetch(:medicare_tax, 0).to_f + totals[:medicare_tax],
      retirement: row.fetch(:retirement, 0).to_f + totals[:retirement],
      roth_retirement: row.fetch(:roth_retirement, 0).to_f + totals[:roth_retirement],
      total_deductions: row.fetch(:total_deductions, 0).to_f + totals[:total_deductions],
      net_pay: row.fetch(:net_pay, 0).to_f + totals[:net_pay],
      payroll_count: row.fetch(:payroll_count, 0).to_i + regular_period_count(paychecks),
      employee_count: (native_employee_ids + paychecks.map(&:employee_id)).compact.uniq.length,
      imported_payroll_count: regular_period_count(paychecks),
      imported_opening_summary_count: opening_summary_count(paychecks)
    )
  end

  def history_row(paycheck)
    totals = historical_totals([ paycheck ])
    {
      key: "imported:#{paycheck.id}",
      record_type: "imported",
      payroll_item_id: nil,
      pay_period_id: nil,
      historical_pay_period_id: paycheck.historical_pay_period_id,
      pay_date: paycheck.pay_date,
      period_description: paycheck.historical_pay_period.source_label,
      scheduled_hours: nil,
      hours_worked: paycheck.hours_total.to_f,
      overtime_hours: nil,
      holiday_hours: nil,
      pto_hours: nil,
      reported_tips: totals[:tips],
      tips_paid_out: totals[:tips_paid_out],
      bonus: 0,
      custom_earnings_total: 0,
      custom_deductions_total: 0,
      gross_pay: paycheck.gross_pay.to_f,
      withholding_tax: paycheck.federal_income_tax.to_f,
      social_security_tax: paycheck.social_security_tax.to_f,
      medicare_tax: paycheck.medicare_tax.to_f,
      total_deductions: totals[:total_deductions],
      net_pay: paycheck.net_pay.to_f,
      check_number: paycheck.check_number,
      payroll_field_entries: [],
      payroll_field_totals: {},
      source: {
        system: "quickbooks_online",
        label: "QuickBooks import",
        locked: true
      },
      capabilities: { view: true, edit: false }
    }
  end

  def source_summary(native_items:, historical_paychecks:, excluded_unlinked_paychecks: [])
    includes_quickbooks = historical_paychecks.any? || excluded_unlinked_paychecks.any?
    {
      mode: includes_quickbooks ? "locked_quickbooks_plus_committed_cornerstone" : "committed_cornerstone_only",
      source_statement: SOURCE_STATEMENT,
      cornerstone: {
        payroll_count: native_items.map(&:pay_period_id).uniq.length,
        paycheck_count: native_items.length
      },
      quickbooks: {
        payroll_count: regular_period_count(historical_paychecks),
        paycheck_count: historical_paychecks.length,
        opening_summary_count: opening_summary_count(historical_paychecks),
        excluded_unlinked_paycheck_count: excluded_unlinked_paychecks.length,
        excluded_unlinked_gross_pay: sum(excluded_unlinked_paychecks, :gross_pay),
        excluded_unlinked_net_pay: sum(excluded_unlinked_paychecks, :net_pay)
      },
      historical_ytd_bridge: bridge_summary
    }
  end

  private

  def historical_scope
    HistoricalPaycheck
      .joins(:historical_import_batch)
      .includes(:historical_import_batch, :historical_pay_period)
      .where(company_id: @company_id, pay_date: @period.range)
      .where(historical_import_batches: { company_id: @company_id, status: "locked" })
  end

  def linked_historical_scope
    historical_scope.where.not(employee_id: nil)
  end

  def historical_totals(paychecks)
    {
      gross_pay: sum(paychecks, :gross_pay),
      withholding_tax: sum(paychecks, :federal_income_tax),
      social_security_tax: sum(paychecks, :social_security_tax),
      medicare_tax: sum(paychecks, :medicare_tax),
      retirement: component_sum(paychecks, :pretax_deduction_breakdown, QuickbooksHistory::YtdBridgePlan::RETIREMENT_PRE_TAX),
      roth_retirement: component_sum(paychecks, :after_tax_deduction_breakdown, QuickbooksHistory::YtdBridgePlan::RETIREMENT_ROTH),
      tips: component_sum(paychecks, :earnings_breakdown, QuickbooksHistory::YtdBridgePlan::TIPS),
      # QuickBooks history does not distinguish reported tips from tips that
      # were paid out through payroll, so do not manufacture a paid-out value.
      tips_paid_out: 0.0,
      total_deductions: paychecks.sum(0.to_d) { |paycheck| paycheck.pretax_deductions + paycheck.employee_taxes + paycheck.after_tax_deductions }.to_f,
      net_pay: sum(paychecks, :net_pay)
    }
  end

  def sum(paychecks, field)
    paychecks.sum(0.to_d) { |paycheck| paycheck.public_send(field).to_d }.to_f
  end

  def component_sum(paychecks, field, pattern)
    paychecks.sum(0.to_d) do |paycheck|
      Array(paycheck.public_send(field)).sum(0.to_d) do |entry|
        component = entry.to_h.with_indifferent_access
        amount = BigDecimal(component[:amount].to_s, exception: false) || 0.to_d
        component[:label].to_s.match?(pattern) ? amount : 0.to_d
      end
    end.to_f
  end

  def regular_period_count(paychecks)
    paychecks.filter_map do |paycheck|
      paycheck.historical_pay_period_id if paycheck.historical_pay_period.period_type == "regular"
    end.uniq.length
  end

  def opening_summary_count(paychecks)
    paychecks.count { |paycheck| paycheck.historical_pay_period.period_type == "opening_summary" }
  end

  def bridge_summary
    balances = HistoricalEmployeeYtdBalance
      .joins(:historical_ytd_bridge)
      .where(company_id: @company_id, tax_year: @period.start_date.year..@period.end_date.year)
      .where(historical_ytd_bridges: { status: "applied" })
    {
      applied: balances.exists?,
      tax_years: balances.distinct.order(:tax_year).pluck(:tax_year),
      through_pay_date: balances.maximum(:through_pay_date),
      through_period_end: balances.maximum(:through_period_end)
    }
  end
end
