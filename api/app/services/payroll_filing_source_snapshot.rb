# frozen_string_literal: true

require "digest"

class PayrollFilingSourceSnapshot
  Result = Struct.new(:snapshot, :fingerprint, keyword_init: true)

  def initialize(company:, tax_year:, quarter: nil)
    @company = company
    @tax_year = Integer(tax_year)
    @quarter = quarter.nil? ? nil : Integer(quarter)
  end

  def call
    snapshot = {
      schema_version: "v1",
      company_id: company.id,
      tax_year: tax_year,
      quarter: quarter,
      period_basis: "pay_date",
      cornerstone_payrolls: cornerstone_payrolls,
      locked_history: locked_history
    }
    fingerprint = Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(snapshot)))
    Result.new(snapshot: snapshot, fingerprint: fingerprint)
  end

  private

  attr_reader :company, :tax_year, :quarter

  def filing_range
    PayrollFilingResponsibilityGate.filing_range(tax_year: tax_year, quarter: quarter)
  end

  def cornerstone_payrolls
    PayPeriod.reportable_committed
             .where(company_id: company.id, pay_date: filing_range)
             .order(:pay_date, :id)
             .map do |pay_period|
      final_record = PayrollFinalRecordService.new(pay_period: pay_period).call
      filing_source = final_record.slice(:pay_period, :official_payroll, :journal, :ytd_reconciliation)
      {
        pay_period_id: pay_period.id,
        pay_date: pay_period.pay_date.iso8601,
        filing_source_fingerprint: Digest::SHA256.hexdigest(
          JSON.generate(QuickbooksHistory::CanonicalJson.normalize(filing_source))
        )
      }
    end
  end

  def locked_history
    batches = HistoricalImportBatch
              .joins(:historical_pay_periods)
              .where(
                company_id: company.id,
                status: "locked",
                historical_pay_periods: { period_type: "regular", pay_date: filing_range }
              )
              .distinct
              .order(:id)

    batches.map do |batch|
      {
        batch_id: batch.id,
        locked_at: batch.locked_at&.iso8601,
        source_files: batch.historical_import_source_files.order(:id).map do |source_file|
          { id: source_file.id, sha256: source_file.sha256 }
        end
      }
    end
  end
end
