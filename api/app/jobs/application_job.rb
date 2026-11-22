class ApplicationJob < ActiveJob::Base
  around_perform do |job, perform|
    Current.with_isolated_actor(AuditActor.system_job(job), &perform)
  end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
