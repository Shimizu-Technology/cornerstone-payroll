# frozen_string_literal: true

class AireHistoryOperationJob < ApplicationJob
  queue_as :default

  def perform(operation_id)
    operation = AireHistoryOperation.find(operation_id)
    operation.with_lock do
      return unless operation.status == "queued"
      raise TimeTracking::HistoryApproval::Error, "Connected payroll is paused; nothing was applied" unless ConnectedPayrollMode.enabled?

      service = TimeTracking::HistoryApproval.new(source: operation.time_tracking_source, actor: operation.actor)
      arguments = operation.arguments.symbolize_keys
      result = if operation.kind == "preview"
        service.prepare!(mapping_selections: arguments.fetch(:mapping_selections))
      else
        review = AireHistoryReview.find_by!(id: arguments.delete(:review_id), company: operation.company,
          time_tracking_source: operation.time_tracking_source, actor: operation.actor)
        service.approve!(review: review, **arguments)
      end
      # The terminal result commits with the same transaction as the approval.
      # A worker restart before commit leaves this operation queued for retry.
      operation.update!(status: "completed", result: result, finished_at: Time.current)
    end
  rescue TimeTracking::HistoryApproval::Error, TimeTracking::VerifiedHistoryRollout::Error,
    TimeTracking::Client::Error, TimeTrackingEmployeeMapping::IdentityConflict, ActiveRecord::RecordNotFound => error
    fail_operation(operation, error.message, error.respond_to?(:changes) ? error.changes : [])
  rescue StandardError => error
    fail_operation(operation, "History processing failed. Nothing was applied. Refresh the summary before retrying.", [])
    raise error
  end

  private

  def fail_operation(operation, message, changes)
    return unless operation&.persisted?
    operation.with_lock do
      operation.update!(status: "failed", error: message, source_changes: changes, finished_at: Time.current) if operation.status == "queued"
    end
  end
end
