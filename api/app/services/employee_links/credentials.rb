# frozen_string_literal: true

module EmployeeLinks
  # Puts a fresh token or one-time code on a link, replacing any earlier one,
  # with a new 14-day expiry. Only digests reach the database.
  module Credentials
    Issued = Data.define(:token, :code)

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
        last_invited_at: now
      )
      Issued.new(token: token, code: code)
    end
  end
end
