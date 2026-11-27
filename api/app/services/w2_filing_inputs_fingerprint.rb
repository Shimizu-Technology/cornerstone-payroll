# frozen_string_literal: true

require "digest"

# Hash filing inputs, never activity timestamps, so a refreshed report or check
# printing does not silently invalidate a genuine accountant attestation.
class W2FilingInputsFingerprint
  RULE_VERSION = "w2-gu-current-inputs-v2"
  ITEM_FIELDS = %w[id employee_id pay_period_id employment_type gross_pay reported_tips
                  withholding_tax additional_withholding social_security_tax medicare_tax
                  non_taxable_pay social_security_taxable_wages social_security_taxable_tips
                  medicare_taxable_wages cash_tips_reported qualified_overtime_compensation
                  tax_rule_snapshot].freeze

  # A caller that already generated this year's W-2GU report may pass it in so
  # the aggregation runs once; it must be the unmodified aggregator output.
  def initialize(company:, year:, report: nil)
    @company = company
    @year = year.to_i
    @report = report
  end

  def call
    report = if @report
      @report.deep_dup
    else
      begin
        W2GuAggregator.new(company, year).generate
      rescue ArgumentError => e
        { input_error: e.message }
      end
    end
    report[:meta]&.delete(:generated_at)
    ids = Array(report[:employees]).map { |row| row.fetch(:employee_id) }
    snapshot = {
      rule_version: RULE_VERSION,
      ss_wage_base: AnnualTaxConfig.for_year(year)&.ss_wage_base || W2GuAggregator::SS_WAGE_BASE_BY_YEAR[year],
      report: report,
      filing_settings: company.attributes.slice("filing_contact_name", "phone", "email", "kind_of_employer", "employment_code", "establishment_number"),
      locked_history: company.historical_import_batches.joins(:historical_paychecks)
        .where(status: "locked", historical_paychecks: { pay_date: year_range }).distinct.order(:id).map do |batch|
          {
            id: batch.id, locked_at: batch.locked_at&.iso8601,
            source_files: batch.historical_import_source_files.order(:id).pluck(:id, :sha256),
            applied_bridge_ids: batch.historical_ytd_bridges.where(status: "applied").order(:id).pluck(:id)
          }
        end,
      identities: Employee.where(company_id: company.id, id: ids).order(:id).map do |employee|
        # Full SSN matters even when its displayed last four digits are
        # unchanged. It goes in keyed (TaxIdDigest): the fingerprint reaches
        # the browser next to the last four digits.
        employee.attributes.slice("id", "first_name", "middle_name", "last_name", "name_suffix", "address_line1", "address_line2", "city", "state", "zip")
          .merge("ssn" => TaxIdDigest.call(employee.ssn_digits))
      end,
      items: PayrollItem.joins(:pay_period).includes(:pay_period).where(company_id: company.id)
        .financially_reportable.reportable.where.not(employment_type: "contractor")
        .where(pay_periods: { id: PayPeriod.reportable_committed.where(company_id: company.id, pay_date: year_range).select(:id) })
        .order(:id).map { |item| item.attributes.slice(*ITEM_FIELDS).merge("pay_date" => item.pay_period.pay_date.iso8601) },
      responsibility: PayrollFilingResponsibilityGate.annual(company: company, tax_year: year).dig(:filings, "w2_gu")
    }
    # Native paychecks inside an opening balance block filing, so a year
    # marked ready before one was detected is stale while it exists. Only
    # added when one exists, so other clients' fingerprints don't move.
    overlaps = PayrollBridgeOverlap.new(company_id: company.id, year: year).w2_blocking
    if overlaps.any?
      snapshot[:bridge_window_overlaps] = overlaps.map { |overlap| [ overlap.payroll_item.id, overlap.batch_id, overlap.evidence_digest ] }.sort
    end
    Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(snapshot)))
  end

  private

  attr_reader :company, :year

  def year_range
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end
end
