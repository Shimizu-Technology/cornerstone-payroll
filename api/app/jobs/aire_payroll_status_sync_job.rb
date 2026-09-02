# frozen_string_literal: true

class AirePayrollStatusSyncJob < ApplicationJob
  queue_as :default

  retry_on TimeTracking::Client::Error, wait: :polynomially_longer, attempts: 8
  discard_on ActiveRecord::RecordNotFound

  def perform(import_id, status, occurred_at)
    import = TimeTrackingImport.includes(:time_tracking_source, pay_period: :company).find(import_id)
    return unless import.finalized_batch? && import.time_tracking_source.source_type == "aire_services"

    TimeTracking::Client.new(import.time_tracking_source).record_payroll_batch_processing_event(
      batch_id: import.external_batch_id,
      event_id: "cornerstone:time-tracking-import:#{import.id}:#{status}",
      status: status,
      occurred_at: occurred_at,
      external_pay_period_id: import.pay_period_id.to_s,
      metadata: {
        company_id: import.pay_period.company_id,
        pay_period_start: import.pay_period.start_date.iso8601,
        pay_period_end: import.pay_period.end_date.iso8601,
        pay_date: import.pay_period.pay_date.iso8601
      }
    )
    import.record_source_processing_sync!(status: status, synced_at: Time.current)
  rescue TimeTracking::Client::Error => e
    import&.update_columns(source_processing_sync_error: e.message, updated_at: Time.current)
    raise
  end
end
