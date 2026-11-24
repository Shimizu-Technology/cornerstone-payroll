# frozen_string_literal: true

module EmployeeLinks
  # Puts a fresh token or one-time code on a link, replacing any earlier one,
  # with a new 14-day expiry. Only digests reach the database.
  #
  # It also owns the one rule for which credential a sign-up request names
  # (select), shared by the Rack throttle key, the controllers and Verify, so
  # all three always act on the same value.
  module Credentials
    Issued = Data.define(:token, :code)
    # The credential a request names: kind is :token or :code; value is the
    # token, or the normalized code.
    Selected = Data.define(:kind, :value) do
      def throttle_key
        Digest::SHA256.hexdigest("#{kind}:#{value}")
      end
    end

    TOKEN_MAX = 256
    CODE_INPUT_MAX = 64
    # The request fields that carry the invite check. They are read from the
    # JSON body only; a request that also puts any of them in the query string
    # is refused, so no layer can read a different value than another.
    FIELDS = %w[token code date_of_birth ssn_last4].freeze

    module_function

    def issue(link, delivery:, email: nil, now: Time.current)
      token = code = nil
      if delivery == "email"
        token = EmployeeAccountLink.generate_token
      else
        code = EmployeeAccountLink.generate_code
      end
      link.assign_attributes(
        invite_delivery: delivery,
        invite_token_digest: token && EmployeeAccountLink.token_digest(token),
        invite_code_digest: code && EmployeeAccountLink.code_digest(code),
        invite_email: delivery == "email" ? EmployeeLinks.normalized_email(email) : nil,
        invite_expires_at: now + EmployeeAccountLink::INVITE_LIFETIME,
        last_invited_at: now,
        # A new generation retires every Clerk sign-up started for the old one.
        invite_generation: link.invite_generation.to_i + 1
      )
      Issued.new(token: token, code: code)
    end

    # A usable token wins; otherwise a code that normalizes to the right
    # length; otherwise nothing.
    def select(token:, code:)
      if token.is_a?(String) && token.present? && token.length <= TOKEN_MAX
        Selected.new(kind: :token, value: token)
      elsif code.is_a?(String) && code.present? && code.length <= CODE_INPUT_MAX
        normalized = EmployeeAccountLink.normalize_code(code)
        Selected.new(kind: :code, value: normalized) if normalized.length == EmployeeAccountLink::CODE_LENGTH
      end
    end

    def conflicting_query?(query_parameters)
      query_parameters.is_a?(Hash) && FIELDS.any? { |field| query_parameters.key?(field) }
    end
  end
end
