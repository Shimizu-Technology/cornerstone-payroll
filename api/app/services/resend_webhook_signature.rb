# frozen_string_literal: true

require "base64"
require "openssl"

# Verifies a Resend webhook (Resend signs with Svix): the svix-signature
# header lists "v1,<base64 HMAC-SHA256>" entries over "<svix-id>.<svix-timestamp>.<raw body>",
# keyed with the base64 part of the endpoint's "whsec_..." secret. Old or
# future timestamps are refused, so a captured request can't be replayed later.
module ResendWebhookSignature
  TOLERANCE = 5.minutes

  module_function

  def valid?(secret:, id:, timestamp:, signatures:, body:, now: Time.current)
    return false if secret.blank? || id.blank? || timestamp.blank? || signatures.blank?

    sent_at = Integer(timestamp.to_s, exception: false)
    return false unless sent_at && (now.to_i - sent_at).abs <= TOLERANCE

    key = Base64.decode64(secret.to_s.delete_prefix("whsec_"))
    return false if key.empty?

    expected = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{body}"))
    signatures.to_s.split(" ").any? do |entry|
      version, signature = entry.split(",", 2)
      version == "v1" && signature.present? && ActiveSupport::SecurityUtils.secure_compare(signature, expected)
    end
  end
end
