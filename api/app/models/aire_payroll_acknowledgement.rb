# frozen_string_literal: true

class AirePayrollAcknowledgement < ApplicationRecord
  STATUSES = TimeTrackingImport::SOURCE_PROCESSING_STATUSES
  REDISPATCH_AFTER = 30.minutes

  belongs_to :time_tracking_import

  validates :event_id, :status, :occurred_at, presence: true
  validates :event_id, uniqueness: true, length: { maximum: 200 }
  validates :status, inclusion: { in: STATUSES }

  scope :undelivered, -> { where(delivered_at: nil) }
  scope :due_for_dispatch, lambda {
    undelivered.where("enqueued_at IS NULL OR enqueued_at < ?", REDISPATCH_AFTER.ago)
  }

  def self.record!(time_tracking_import:, status:, occurred_at:)
    event_id = "cornerstone:time-tracking-import:#{time_tracking_import.id}:#{status}"
    create_or_find_by!(event_id: event_id) do |acknowledgement|
      acknowledgement.time_tracking_import = time_tracking_import
      acknowledgement.status = status
      acknowledgement.occurred_at = occurred_at
    end
  end

  def self.dispatch_pending!(ids: nil)
    scope = due_for_dispatch
    scope = scope.where(id: ids) if ids.present?
    scope.find_each(&:dispatch!)
  end

  def dispatch!
    with_lock do
      return false if delivered_at.present?
      return false if enqueued_at.present? && enqueued_at >= REDISPATCH_AFTER.ago

      AirePayrollStatusSyncJob.perform_later(id)
      update!(enqueued_at: Time.current, last_error: nil)
    end
    true
  rescue StandardError => e
    update_columns(last_error: e.message, updated_at: Time.current) if persisted?
    begin
      time_tracking_import.record_source_processing_failure!(status: status, message: e.message) if persisted?
    rescue StandardError => state_error
      Rails.logger.error("AIRE payroll acknowledgement #{id || event_id} could not record its enqueue failure: #{state_error.message}")
    end
    Rails.logger.error("AIRE payroll acknowledgement #{id || event_id} could not be enqueued: #{e.message}")
    false
  end

  def mark_delivered!(at:)
    update!(delivered_at: at, last_error: nil)
  end

  def record_delivery_failure!(message)
    update!(last_error: message)
  end
end
