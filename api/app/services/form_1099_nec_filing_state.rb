# frozen_string_literal: true

# One client's 1099-NEC filing state for a tax year, read together: the
# filing decision, the 1099-NEC report, the inputs fingerprint and the "1099s
# ready" sign-off. The checklist, the clients list, mark ready, the official
# copies and the 1099 e-file all read it here, so they agree on what "final"
# means (Form1099FilingReadiness.final?).
#
# Callers that must not act on a sign-off that changes while they work (mark
# ready, downloads) hold the company lock, which mark ready takes too.
class Form1099NecFilingState
  Result = Struct.new(:cornerstone_files, :report, :report_error, :fingerprint, :readiness, :final, keyword_init: true) do
    def current?
      readiness.present? && readiness.current?(fingerprint)
    end

    def reportable_rows
      Array(report&.dig(:reportable_contractors))
    end

    # The rows that get a 1099: contractor records, including any one-off
    # checks linked to them. Unlinked one-off payees have no TIN or address.
    def payee_rows
      reportable_rows.select { |row| row[:employee_id] }
    end

    # Changes whenever the sign-off, the inputs or the decision change.
    def signature
      { cornerstone_files: cornerstone_files, fingerprint: fingerprint, final: final,
        readiness: readiness && [ readiness.id, readiness.ready_fingerprint, readiness.marked_ready_at&.utc&.iso8601(6) ] }
    end
  end

  def self.call(company:, year:)
    new(company: company, year: year).call
  end

  # report / report_error: a 1099-NEC report the caller already built (or the
  # message it failed with), so it is not built twice.
  def initialize(company:, year:, report: nil, report_error: nil)
    @company = company
    @year = Integer(year)
    @preloaded = report || report_error ? [ report, report_error ] : nil
  end

  def call
    files = company.payroll_filing_responsibilities
      .find_by(tax_year: year, quarter: nil, filing_type: "form_1099")&.responsible_party == "cornerstone"
    return Result.new(cornerstone_files: false, final: false) unless files

    report, error = @preloaded || load_report
    fingerprint = Form1099InputsFingerprint.new(company: company, year: year, report: report).call if report
    # Read after the fingerprint, so a sign-off made while it was computed is seen.
    readiness = Form1099FilingReadiness.find_by(company_id: company.id, tax_year: year)
    Result.new(
      cornerstone_files: true, report: report, report_error: error, fingerprint: fingerprint, readiness: readiness,
      final: report.present? && Form1099FilingReadiness.final?(company: company, year: year, readiness: readiness, fingerprint: fingerprint)
    )
  end

  private

  attr_reader :company, :year

  def load_report
    [ Form1099NecAggregator.new(company, year).generate, nil ]
  rescue ActiveRecord::RecordNotFound, ArgumentError => e
    [ nil, e.message ]
  end
end
