# frozen_string_literal: true

Rails.application.config.after_initialize do
  next unless StagingOutboundPolicy.staging? && Rails.env.production?
  tasks = defined?(Rake) ? Rake.application.top_level_tasks : []
  StagingExecutionGate.enforce! unless StagingExecutionGate.maintenance_only?(tasks)
end

# A second fence covers explicit starts from a previously initialized Rake
# invocation as well as submissions from a controlled maintenance process.
require "solid_queue/supervisor"
module StagingQueueStartGuard
  def start(...)
    StagingExecutionGate.enforce!
    super
  end
end
SolidQueue::Supervisor.singleton_class.prepend(StagingQueueStartGuard)
SolidQueue::Supervisor.prepend(StagingQueueStartGuard)

module StagingQueueSubmissionGuard
  def enqueue(...)
    StagingExecutionGate.enforce!
    super
  end

  def enqueue_at(...)
    StagingExecutionGate.enforce!
    super
  end

  def enqueue_all(...)
    StagingExecutionGate.enforce!
    super
  end
end
ActiveJob::QueueAdapters::SolidQueueAdapter.prepend(StagingQueueSubmissionGuard)
