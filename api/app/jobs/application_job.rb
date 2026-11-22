class ApplicationJob < ActiveJob::Base
  def perform_now
    # Active Job handles retries and discards after the perform callbacks unwind.
    Current.with_isolated_actor(AuditActor.system_job(self)) { super }
  end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
