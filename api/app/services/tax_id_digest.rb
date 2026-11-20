# frozen_string_literal: true

require "openssl"

# A keyed digest of a full SSN or TIN, for filing-input fingerprints that
# reach the browser (W2FilingInputsFingerprint, Form1099InputsFingerprint).
# An unkeyed hash over a snapshot holding a full SSN could be brute-forced
# from the last four digits the same response shows (10^5 candidates). The
# key is derived from secret_key_base with a dedicated salt, so it stays the
# same across restarts and deploys while only the server can compute it.
# A changed SSN or TIN still changes the digest, and so the fingerprint.
module TaxIdDigest
  SALT = "filing-inputs-fingerprint tax id v1"

  def self.call(value)
    digits = value.to_s.gsub(/\D/, "")
    return nil if digits.empty?

    OpenSSL::HMAC.hexdigest("SHA256", key, digits)
  end

  def self.key
    @key ||= Rails.application.key_generator.generate_key(SALT, 32)
  end
end
