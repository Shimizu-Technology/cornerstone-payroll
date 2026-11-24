# frozen_string_literal: true

module EmployeeLinks
  # Staff end an employee's app access, recording who, why and when (D12).
  # The link check on every request ends access at once; an employee-only
  # login with nothing else left is also deactivated and signed out.
  class Revoke
    REASON_MAX = 500

    def self.call(link:, actor:, reason:, request: nil)
      EmployeeLinks.require_staff!(actor, link.company)
      reason = reason.to_s.strip
      raise Error, "Give a reason for ending this employee's app access" if reason.empty?
      raise Error, "Keep the reason under #{REASON_MAX} characters" if reason.length > REASON_MAX

      ApplicationRecord.transaction do
        unless Close.lock_link_and_login!(link)
          raise Error, "This employee's app access changed while it was being ended. Try again."
        end
        raise Error, "This employee's app access has already ended" if link.revoked?

        Close.revoke!(link, reason: reason, actor: actor, request: request).tap do
          Current.domain_audit_recorded = true
        end
      end
    end
  end
end
