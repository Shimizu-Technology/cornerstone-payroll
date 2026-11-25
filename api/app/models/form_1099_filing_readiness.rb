# frozen_string_literal: true

# The "1099s ready" sign-off for one client and tax year. It is bound to
# Form1099InputsFingerprint: payer identity, each payee's TIN, name and
# address, the amounts, and which one-off checks are linked to whom. It counts
# only while that fingerprint still matches the current inputs.
class Form1099FilingReadiness < ApplicationRecord
  self.table_name = "form_1099_filing_readinesses"

  belongs_to :company
  belongs_to :marked_ready_by, class_name: "User", optional: true

  validates :tax_year, numericality: { only_integer: true, greater_than_or_equal_to: 2000, less_than_or_equal_to: 2200 }
  validates :tax_year, uniqueness: { scope: :company_id }
  validates :ready_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :notes, length: { maximum: 2_000 }
  validate :preserve_attestation_history

  # The single rule for "final" 1099 output: official copies without the
  # DRAFT watermark and the filing-ready e-file. The sign-off must match these
  # exact inputs, Cornerstone must file this client's 1099s for the year, and
  # a practice workspace never produces final output. A demo's copies are
  # final like a live client's; its e-file downloads are refused separately.
  def self.final?(company:, year:, readiness:, fingerprint:)
    return false if company.practice_copy?
    return false unless readiness&.current?(fingerprint)

    company.payroll_filing_responsibilities
      .find_by(tax_year: year, quarter: nil, filing_type: "form_1099")&.responsible_party == "cornerstone"
  end

  def current?(fingerprint)
    ready_fingerprint.present? && fingerprint.present? && ready_fingerprint == fingerprint
  end

  def marked?
    ready_fingerprint.present?
  end

  def payload(fingerprint:)
    {
      tax_year: tax_year,
      status: current?(fingerprint) ? "filing_ready" : (marked? ? "stale" : "draft"),
      stale: marked? && !current?(fingerprint),
      marked_ready_at: marked_ready_at&.iso8601,
      marked_ready_by: marked_ready_by_name,
      notes: notes,
      payee_count: payee_count,
      total_compensation: total_compensation.to_d.round(2).to_f
    }
  end

  private

  def preserve_attestation_history
    return if new_record? || !will_save_change_to_attestation_history?

    retained = attestation_history_in_database || []
    errors.add(:attestation_history, "cannot rewrite previous sign-offs") unless attestation_history.first(retained.length) == retained
  end
end
