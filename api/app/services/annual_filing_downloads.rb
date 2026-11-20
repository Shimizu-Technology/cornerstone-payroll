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
    if @filing_type == "w2_gu_w3_ss"
      W2FilingInputsFingerprint.new(company: @company.reload, year: @year).call
    else
      self.class.form1099_fingerprint(company: @company, year: @year)
    end
  end

  def self.form1099_fingerprint(company:, year:)
    Form1099InputsFingerprint.new(company: company, year: year).call
  end
end
