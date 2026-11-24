# frozen_string_literal: true

module EmployeeLinks
  # Staff clear a sign-up lock before its 24 hours are up.
  class Unlock
    def self.call(link:, actor:, request: nil)
      EmployeeLinks.require_staff!(actor, link.company)
      link.with_lock do
        raise Error, "This sign-up isn't locked" unless link.activation_locked? || link.failed_activation_attempts.positive?

        previous = link.failed_activation_attempts
        link.update!(failed_activation_attempts: 0, activation_locked_at: nil, activation_locked_until: nil)
        EmployeeLinks.audit!(link, "activation_unlocked", user: actor, request: request,
          metadata: { failed_attempts_cleared: previous })
      end
      link
    end
  end
end
