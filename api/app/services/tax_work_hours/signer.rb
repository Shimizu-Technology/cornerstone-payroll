# frozen_string_literal: true

require "erb"
require "openssl"

module TaxWorkHours
  # Signs Work Hours v1 requests exactly as Cornerstone Tax verifies them
  # (Tax: docs/PAYROLL_WORK_HOURS_FEED.md, Payroll::WorkHoursSignature).
  #
  #   string_to_sign = METHOD \n path \n canonical_query \n timestamp \n sha256_hex(body)
  #   signature      = lower-case hex HMAC-SHA256(secret, string_to_sign)
  #
  # The canonical query re-encodes every name and value per RFC 3986
  # (ERB::Util.url_encode keeps A-Z a-z 0-9 - _ . ~ and upper-cases %XX),
  # sorts by name then value and joins with "&". Each key is sent once: the
  # query is a Hash, and Tax rejects repeated keys.
  module Signer
    TIMESTAMP_HEADER = "X-Work-Hours-Timestamp"
    SIGNATURE_HEADER = "X-Work-Hours-Signature"
    PATH = "/api/v1/payroll/work_hours"

    module_function

    def canonical_query(query)
      names = query.keys.map(&:to_s)
      raise ArgumentError, "query keys must be unique" unless names.uniq.length == names.length

      query.map { |name, value| [ name.to_s, value.to_s ] }.sort
           .map { |name, value| "#{ERB::Util.url_encode(name)}=#{ERB::Util.url_encode(value)}" }.join("&")
    end

    def string_to_sign(method:, path:, canonical_query:, timestamp:, body: "")
      [ method.to_s.upcase, path, canonical_query, timestamp.to_s, OpenSSL::Digest::SHA256.hexdigest(body.to_s) ].join("\n")
    end

    # Returns [request_uri, headers] for the request, signed at `now`.
    def signed(secret:, query:, path: PATH, method: "GET", body: "", now: Time.now)
      raise ArgumentError, "secret is required" if secret.to_s.empty?

      canonical = canonical_query(query)
      timestamp = now.to_i.to_s
      signature = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s,
                                          string_to_sign(method: method, path: path, canonical_query: canonical, timestamp: timestamp, body: body))
      [ canonical.empty? ? path : "#{path}?#{canonical}",
        { TIMESTAMP_HEADER => timestamp, SIGNATURE_HEADER => signature } ]
    end
  end
end
