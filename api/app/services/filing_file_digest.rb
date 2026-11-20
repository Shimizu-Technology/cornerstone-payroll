# frozen_string_literal: true

require "openssl"

# A keyed digest of a year-end filing file (Pub 1220, 1096, EFW2, W-3SS and
# the official W-2GU/1099-NEC copy PDFs), written to the download's AuditLog
# row so a later filing record can prove which bytes were sent.
#
# An unkeyed SHA-256 there would leak full SSNs and TINs: the files are
# deterministic, the audit history is visible to accountants, and everything
# else in a file can be rebuilt from data they see plus the last four
# digits, so a single-payee file's SSN prefix falls to 10^5 guesses offline.
# The HMAC key is derived from secret_key_base with its own salt (the same
# scheme as TaxIdDigest, a different key), so only the server can compute or
# check a digest, and it stays stable across restarts and deploys.
module FilingFileDigest
  SALT = "year-end filing file digest v1"
  ALGORITHM = "hmac-sha256-v1"

  # Audit actions whose metadata describes a year-end filing file. Their
  # metadata never carries an unkeyed "sha256" out of the audit API or CSV.
  AUDIT_ACTIONS = %w[
    pub1220#download
    form1096#download
    efw2#download
    w3ss#download
    reports#w2_gu_copy_1_drt
    reports#w2_gu_employee_copies
    reports#form_1099_nec_payer_record
    reports#form_1099_nec_recipient_copies
  ].freeze

  UNKEYED_KEYS = %w[sha256].freeze

  # Hex HMAC-SHA256 of the file's bytes.
  def self.call(bytes, key: self.key)
    OpenSSL::HMAC.hexdigest("SHA256", key, bytes.to_s.b)
  end

  # The audit metadata for a download of +bytes+.
  def self.audit_metadata(bytes)
    { file_digest: call(bytes), digest_alg: ALGORITHM }
  end

  # True when +bytes+ are the file a download's audit metadata describes.
  # Accepts an AuditLog, its metadata hash, or a bare hex digest.
  def self.matches?(bytes, record)
    metadata = record.respond_to?(:metadata) ? record.metadata : record
    expected =
      if metadata.is_a?(Hash)
        return false unless metadata.with_indifferent_access[:digest_alg] == ALGORITHM

        metadata.with_indifferent_access[:file_digest]
      else
        metadata
      end
    return false unless expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/)

    ActiveSupport::SecurityUtils.secure_compare(call(bytes), expected)
  end

  # Audit metadata as shown to people: a year-end filing download's
  # metadata loses any unkeyed file hash. Other actions pass through.
  def self.redact_audit_metadata(action, metadata)
    return metadata unless metadata.is_a?(Hash) && AUDIT_ACTIONS.include?(action.to_s)

    metadata.reject { |key, _| UNKEYED_KEYS.include?(key.to_s) }
  end

  def self.key
    @key ||= Rails.application.key_generator.generate_key(SALT, 32)
  end
end
