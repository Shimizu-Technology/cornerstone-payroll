# frozen_string_literal: true

# Only portal-upload files qualify: printed copies and transmittal PDFs do not.
class AnnualFilingDownloads
  def initialize(company:, year:, filing_type:)
    @company, @year, @filing_type = company, year, filing_type
  end

  def logs
    return AuditLog.none unless @filing_type.in?(PayrollFilingRecord::ANNUAL_TYPES)

    AuditLog.where(company_id: @company.id, action: @filing_type == "w2_gu_w3_ss" ? "efw2#download" : "pub1220#download")
      .where("metadata->>'file_digest' ~ '^[0-9a-f]{64}$'")
      .where("metadata->>'digest_alg' = ?", FilingFileDigest::ALGORITHM)
      .where("metadata->>'year' = ? AND metadata->>'mode' = 'final'", @year.to_s).newest_first
  end

  def fingerprint
    @fingerprint ||= if @filing_type == "w2_gu_w3_ss"
      W2FilingInputsFingerprint.new(company: @company.reload, year: @year).call
    else
      self.class.form1099_fingerprint(company: @company, year: @year)
    end
  end

  # nil when the inputs can't be read yet, such as a 1099 year with no
  # reporting threshold configured.
  def readable_fingerprint
    fingerprint
  rescue ArgumentError, ActiveRecord::RecordNotFound
    nil
  end

  # What a download must carry to be the file to submit now: nil unless the
  # client's sign-off still matches the current inputs.
  def current_fingerprint
    return @current_fingerprint if defined?(@current_fingerprint)

    current = readable_fingerprint
    @current_fingerprint = current && final?(current) ? current : nil
  rescue ArgumentError, ActiveRecord::RecordNotFound
    @current_fingerprint = nil
  end

  def final?(current)
    if @filing_type == "w2_gu_w3_ss"
      readiness = W2FilingReadiness.find_by(company_id: @company.id, year: @year)
      !@company.test_workspace? && W2GuOfficialCopies.final?(company: @company, year: @year, readiness: readiness, fingerprint: current)
    else
      Form1099Readiness.final?(company: @company, year: @year)
    end
  end

  def self.form1099_fingerprint(company:, year:)
    Form1099InputsFingerprint.new(company: company, year: year).call
  end
end
