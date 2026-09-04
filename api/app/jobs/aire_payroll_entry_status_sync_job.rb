# frozen_string_literal: true

class AirePayrollEntryStatusSyncJob < ApplicationJob
  queue_as :default

  retry_on TimeTracking::Client::Error, wait: :polynomially_longer, attempts: 8
  discard_on ActiveRecord::RecordNotFound

  def perform(acknowledgement_id)
    acknowledgement = AirePayrollEntryAcknowledgement.includes(
      time_tracking_import: [ :time_tracking_source, { pay_period: :company } ]
    ).find(acknowledgement_id)
    return if acknowledgement.delivered_at.present?

    import = acknowledgement.time_tracking_import
    return unless import.finalized_batch? && import.time_tracking_source.source_type == "aire_services"

    TimeTracking::Client.new(import.time_tracking_source).record_payroll_entry_processing_event(
      batch_id: import.external_batch_id,
      event_id: acknowledgement.event_id,
      status: acknowledgement.status,
      occurred_at: acknowledgement.occurred_at.iso8601,
      external_pay_period_id: import.pay_period_id.to_s,
      external_payroll_item_id: acknowledgement.payroll_item_id.to_s,
      source_time_entry_id: acknowledgement.source_time_entry_id,
      source_user_uuid: acknowledgement.source_user_uuid,
      payment_method: acknowledgement.payment_method,
      payment_reference: acknowledgement.payment_reference,
      metadata: {
        company_id: import.pay_period.company_id,
        pay_period_start: import.pay_period.start_date.iso8601,
        pay_period_end: import.pay_period.end_date.iso8601,
        pay_date: import.pay_period.pay_date.iso8601
      }
    )
    acknowledgement.mark_delivered!(at: Time.current)
  rescue TimeTracking::Client::Error => e
    acknowledgement&.record_delivery_failure!(e.message)
    raise
  end
end
