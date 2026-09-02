# frozen_string_literal: true

class AirePayrollStatusSyncJob < ApplicationJob
  queue_as :default

  retry_on TimeTracking::Client::Error, wait: :polynomially_longer, attempts: 8
  discard_on ActiveRecord::RecordNotFound

  def perform(acknowledgement_id)
    acknowledgement = AirePayrollAcknowledgement.includes(
      time_tracking_import: [ :time_tracking_source, { pay_period: :company } ]
    ).find(acknowledgement_id)
    return if acknowledgement.delivered_at.present?

    import = acknowledgement.time_tracking_import
    status = acknowledgement.status
    return unless import.finalized_batch? && import.time_tracking_source.source_type == "aire_services"

    TimeTracking::Client.new(import.time_tracking_source).record_payroll_batch_processing_event(
      batch_id: import.external_batch_id,
      event_id: acknowledgement.event_id,
      status: status,
      occurred_at: acknowledgement.occurred_at.iso8601,
      external_pay_period_id: import.pay_period_id.to_s,
      metadata: {
        company_id: import.pay_period.company_id,
        pay_period_start: import.pay_period.start_date.iso8601,
        pay_period_end: import.pay_period.end_date.iso8601,
        pay_date: import.pay_period.pay_date.iso8601
      }
    )
    delivered_at = Time.current
    import.record_source_processing_sync!(status: status, synced_at: delivered_at)
    acknowledgement.mark_delivered!(at: delivered_at)
  rescue TimeTracking::Client::Error => e
    acknowledgement&.record_delivery_failure!(e.message)
    import&.record_source_processing_failure!(status: status, message: e.message)
    raise
  end
end
