# frozen_string_literal: true

class ConnectedPayrollJob < ApplicationJob
  around_perform do |job, perform|
    if ConnectedPayrollMode.enabled?
      perform.call
    else
      # retry_job does not increment exception_executions / retry_on budgets.
      # Keep one-shot work durable; recurring dispatchers also safely recheck.
      job.retry_job(wait: 1.minute) if job.arguments.any?
    end
  end
end
