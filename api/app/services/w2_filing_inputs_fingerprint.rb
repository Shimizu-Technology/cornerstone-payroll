# frozen_string_literal: true

require "digest"

# Hash filing inputs, never activity timestamps, so a refreshed report or check
# printing does not silently invalidate a genuine accountant attestation.
class W2FilingInputsFingerprint
  RULE_VERSION = "w2-gu-current-inputs-v1"
  ITEM_FIELDS = %w[id employee_id pay_period_id employment_type gross_pay reported_tips
                  withholding_tax additional_withholding social_security_tax medicare_tax
                  non_taxable_pay social_security_taxable_wages social_security_taxable_tips
                  medicare_taxable_wages cash_tips_reported qualified_overtime_compensation
                  tax_rule_snapshot].freeze

  def initialize(company:, year:)
    @company = company
    @year = year.to_i
  end

  def call
    report = begin
      W2GuAggregator.new(company, year).generate
    rescue ArgumentError => e
      { input_error: e.message }
    end
    report[:meta]&.delete(:generated_at)
    ids = Array(report[:employees]).map { |row| row.fetch(:employee_id) }
    snapshot = {
      rule_version: RULE_VERSION,
      ss_wage_base: AnnualTaxConfig.for_year(year)&.ss_wage_base || W2GuAggregator::SS_WAGE_BASE_BY_YEAR[year],
      report: report,
      locked_history: company.historical_import_batches.joins(:historical_paychecks)
        .where(status: "locked", historical_paychecks: { pay_date: year_range }).distinct.order(:id).map do |batch|
          {
            id: batch.id, locked_at: batch.locked_at&.iso8601,
            source_files: batch.historical_import_source_files.order(:id).pluck(:id, :sha256),
            applied_bridge_ids: batch.historical_ytd_bridges.where(status: "applied").order(:id).pluck(:id)
          }
        end,
      identities: Employee.where(company_id: company.id, id: ids).order(:id).map do |employee|
        # Full SSN matters even when its displayed last four digits are unchanged.
        employee.attributes.slice("id", "first_name", "last_name", "address_line1", "address_line2", "city", "state", "zip")
          .merge("ssn" => employee.ssn_digits)
      end,
      items: PayrollItem.joins(:pay_period).includes(:pay_period).where(company_id: company.id)
        .not_voided.reportable.where.not(employment_type: "contractor")
        .where(pay_periods: { id: PayPeriod.reportable_committed.where(company_id: company.id, pay_date: year_range).select(:id) })
        .order(:id).map { |item| item.attributes.slice(*ITEM_FIELDS).merge("pay_date" => item.pay_period.pay_date.iso8601) },
      responsibility: PayrollFilingResponsibilityGate.annual(company: company, tax_year: year).dig(:filings, "w2_gu")
    }
    Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(snapshot)))
  end

  private

  attr_reader :company, :year

  def year_range
    Date.new(year, 1, 1)..Date.new(year, 12, 31)
  end
end
