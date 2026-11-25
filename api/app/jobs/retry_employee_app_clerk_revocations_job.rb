# frozen_string_literal: true

# Recovers demo kill switch Clerk revocations (M4-9d) left without a job: a
# crash or failed enqueue after the stop committed, or a job lost from the
# queue. Re-enqueues each stale pending row (EmployeeAppClerkRevocation.stale)
# through the same atomic claim a repeat stop uses, so only one of them
# queues it; the job it replaces, if that was only delayed, no longer owns
# the row and does nothing.
class RetryEmployeeAppClerkRevocationsJob < ApplicationJob
  BATCH = 200

  self.rls_mode = :system

  queue_as :default

  def perform(now: Time.current)
    ids = EmployeeAppClerkRevocation.stale(now).order(:enqueued_at, :id).limit(BATCH).pluck(:id)
    queued = EmployeeAppClerkRevocation.enqueue!(ids, now: now, stale: true)
    Rails.logger.info("[RetryEmployeeAppClerkRevocationsJob] re-enqueued=#{queued.size}") if queued.any?
    queued.size
  end
end
