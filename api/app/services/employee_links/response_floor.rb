# frozen_string_literal: true

module EmployeeLinks
  # A short minimum time, with a little jitter, for the generic answers of
  # sign-up, claim and reactivation, so how long a refusal takes says little
  # about why. It is applied after the action finished and its database
  # connection went back to the pool (EmployeeLinkCheckParams), so no lock or
  # connection is held while waiting. It is bounded (at most MINIMUM + JITTER) and those
  # routes are rate limited per IP, token and session, so it can't tie up
  # many threads.
  module ResponseFloor
    MINIMUM = 0.35
    JITTER = 0.1

    module_function

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wait_since(started_at)
      return unless enabled?

      remaining = MINIMUM + (SecureRandom.random_number * JITTER) - (now - started_at)
      pause(remaining.clamp(0, MINIMUM + JITTER)) if remaining.positive?
    end

    def enabled?
      !Rails.env.test?
    end

    def pause(seconds)
      sleep(seconds)
    end
  end
end
