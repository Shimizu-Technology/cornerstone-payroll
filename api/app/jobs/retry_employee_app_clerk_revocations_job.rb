# frozen_string_literal: true

# Recovers demo kill switch Clerk revocations (M4-9d) left without a job: a
# crash or failed enqueue after the stop committed, or a job lost from the
# queue. Re-enqueues each stale pending row (EmployeeAppClerkRevocation.stale);
# RevokeEmployeeAppClerkJob does nothing for a row no longer pending, so a
# duplicate job is harmless.
class RetryEmployeeAppClerkRevocationsJob < ApplicationJob
  BATCH = 200

  self.rls_mode = :system

  queue_as :default

  def perform(now: Time.current)
    ids = EmployeeAppClerkRevocation.stale(now).order(:enqueued_at, :id).limit(BATCH).pluck(:id)
    queued = EmployeeAppClerkRevocation.enqueue!(ids, now: now)
    Rails.logger.info("[RetryEmployeeAppClerkRevocationsJob] re-enqueued=#{queued.size}") if queued.any?
    queued.size
  end
end
