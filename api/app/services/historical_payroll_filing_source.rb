# frozen_string_literal: true

# Read-only filing input for an explicitly authorized historical-payroll source.
#
# Annual returns consume the latest applied YTD bridge for each locked import so
# opening summaries and reviewed adjustments are included exactly once. Quarterly
# returns consume dated ledger entries and deliberately exclude opening summaries,
# which cannot be assigned to a filing quarter without paycheck-level evidence.
class HistoricalPayrollFilingSource
  HistoricalRecord = Data.define(
    :key, :record_type, :record_id, :historical_pay_period_id,
    :employee_id, :pay_date, :period_start, :period_end,
    :gross_pay, :net_pay, :pretax_deductions, :after_tax_deductions,
    :non_taxable_pay, :reported_tips, :withholding_tax, :additional_withholding,
    :social_security_tax, :employer_social_security_tax,
    :medicare_tax, :employer_medicare_tax,
    :social_security_taxable_wages, :social_security_taxable_tips,
    :medicare_taxable_wages, :additional_medicare_taxable_wages
  ) do
    def historical_source?
      true
    end

    def total_income_tax_withheld
      withholding_tax.to_d + additional_withholding.to_d
    end
  end

  attr_reader :company

  def initialize(company)
    @company = company
  end

  def validate!(range:)
    missing_bridges = locked_batches(range: range).reject { |batch| batch.latest_applied_historical_ytd_bridge }
    if missing_bridges.any?
      raise ArgumentError, "Locked QuickBooks history requires an applied historical YTD bridge before it can be used for filing preparation"
    end

    stale_batches = eligible_batch_bridges(range: range).filter_map do |batch, bridge|
      expected_digest = bridge.preview_summary.to_h["adjustment_digest"].to_s
      batch if expected_digest.blank? || expected_digest != HistoricalPayroll::Ledger.new(batch: batch).adjustment_digest
    end
    if stale_batches.any?
      raise ArgumentError, "Locked QuickBooks history has adjustments that are not represented by the latest historical YTD bridge"
    end

    self
  end

  def annual_balances(year)
    range = Date.new(year, 1, 1)..Date.new(year, 12, 31)
    HistoricalEmployeeYtdBalance
      .includes(:employee)
      .where(historical_ytd_bridge_id: bridge_ids(range: range), company_id: company.id, tax_year: year)
      .where.not(employee_id: nil)
      .to_a
  end

  def records(range:, include_opening_summaries: false)
    eligible_batch_bridges(range: range).flat_map do |batch, _bridge|
      HistoricalPayroll::Ledger.new(batch: batch).entries.filter_map do |entry|
        next unless range.cover?(entry.pay_date)
        if entry.record_type == "source_snapshot" && entry.historical_pay_period.period_type != "regular"
          next unless include_opening_summaries
        end
        next unless entry.employee_id

        historical_record(entry)
      end
    end
  end

  def opening_summary_count(range:)
    HistoricalPaycheck
      .joins(:historical_pay_period)
      .where(historical_import_batch_id: eligible_batch_ids(range: range), company_id: company.id, pay_date: range)
      .where.not(employee_id: nil)
      .where(historical_pay_periods: { period_type: "opening_summary" })
      .count
  end

  def metadata(year:, range:)
    balances = annual_balances(year)
    dated_records = records(range: range)
    source_records = dated_records.select { |record| record.record_type == "source_snapshot" }
    {
      locked_import_count: eligible_batch_ids(range: range).length,
      bridge_balance_count: balances.length,
      dated_record_count: dated_records.length,
      pay_period_count: source_records.map(&:historical_pay_period_id).uniq.length,
      opening_summary_count_excluded: opening_summary_count(range: range)
    }
  end

  private

  def locked_batches(range:)
    HistoricalImportBatch
      .joins(:historical_paychecks)
      .where(company_id: company.id, status: "locked", historical_paychecks: { pay_date: range })
      .includes(:latest_applied_historical_ytd_bridge)
      .distinct
      .order(:id)
      .to_a
  end

  def eligible_batch_bridges(range:)
    locked_batches(range: range).filter_map do |batch|
      bridge = batch.latest_applied_historical_ytd_bridge
      [ batch, bridge ] if bridge
    end
  end

  def eligible_batch_ids(range:)
    eligible_batch_bridges(range: range).map { |batch, _bridge| batch.id }
  end

  def bridge_ids(range:)
    eligible_batch_bridges(range: range).map { |_batch, bridge| bridge.id }
  end

  def historical_record(entry)
    gross_pay = entry.gross_pay.to_d
    reported_tips = component_sum(entry.earnings_breakdown, QuickbooksHistory::YtdBridgePlan::TIPS)
    non_taxable = component_sum(entry.earnings_breakdown, QuickbooksHistory::YtdBridgePlan::NON_TAXABLE_EARNING)
    fica_exempt_pretax = component_sum(
      entry.pretax_deduction_breakdown,
      QuickbooksHistory::YtdBridgePlan::FICA_EXEMPT_PRETAX_DEDUCTION
    )
    fica_wages = (gross_pay - non_taxable - fica_exempt_pretax).round(2)
    taxable_tips = if fica_wages.negative?
      0.to_d
    else
      [ reported_tips, fica_wages ].min
    end

    HistoricalRecord.new(
      key: "quickbooks:#{entry.record_type}:#{entry.record_id}",
      record_type: entry.record_type,
      record_id: entry.record_id,
      historical_pay_period_id: entry.historical_pay_period.id,
      employee_id: entry.employee_id,
      pay_date: entry.pay_date,
      period_start: entry.period_start,
      period_end: entry.period_end,
      gross_pay: gross_pay,
      net_pay: entry.net_pay.to_d,
      pretax_deductions: entry.pretax_deductions.to_d,
      after_tax_deductions: entry.after_tax_deductions.to_d,
      non_taxable_pay: non_taxable,
      reported_tips: reported_tips,
      withholding_tax: entry.federal_income_tax.to_d,
      additional_withholding: 0.to_d,
      social_security_tax: entry.social_security_tax.to_d,
      employer_social_security_tax: component_sum(entry.employer_tax_breakdown, /\A(?:SS|Social Security(?: Employer)?)\z/i),
      medicare_tax: entry.medicare_tax.to_d,
      employer_medicare_tax: component_sum(entry.employer_tax_breakdown, /\A(?:Med|Medicare(?: Employer)?)\z/i),
      social_security_taxable_wages: (fica_wages - taxable_tips).round(2),
      social_security_taxable_tips: taxable_tips.round(2),
      medicare_taxable_wages: fica_wages,
      additional_medicare_taxable_wages: nil
    )
  end

  def component_sum(entries, pattern)
    Array(entries).sum(0.to_d) do |entry|
      value = entry.to_h.with_indifferent_access
      value[:label].to_s.match?(pattern) ? (BigDecimal(value[:amount].to_s, exception: false) || 0.to_d) : 0.to_d
    end.round(2)
  end
end
