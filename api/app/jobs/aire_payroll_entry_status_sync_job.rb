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
    dependencies = Array(acknowledgement.delivery_dependencies)
    unless AirePayrollEntryAcknowledgement.where(id: dependencies).where.not(delivered_at: nil).count == dependencies.length
      raise TimeTracking::Client::Error, "An earlier source payment receipt must be delivered before this transition"
    end

    import = acknowledgement.time_tracking_import
    return unless import.finalized_batch?

    payable_line = if acknowledgement.contract_version.present?
      {
        contract_version: acknowledgement.contract_version,
        source_line_key: acknowledgement.source_line_key,
        source_kind: acknowledgement.source_kind,
        total_hours: acknowledgement.total_hours.to_s,
        regular_hours: acknowledgement.regular_hours.to_s,
        overtime_hours: acknowledgement.overtime_hours.to_s
      }
    else
      {}
    end

    TimeTracking::Client.new(import.time_tracking_source).record_payroll_entry_processing_event(
      batch_id: import.external_batch_id,
      event_id: acknowledgement.event_id,
      status: acknowledgement.status,
      occurred_at: acknowledgement.occurred_at.iso8601(6),
      external_pay_period_id: import.pay_period_id.to_s,
      external_payroll_item_id: acknowledgement.payroll_item_id.to_s,
      source_time_entry_id: acknowledgement.source_time_entry_id,
      source_user_uuid: acknowledgement.source_user_uuid,
      **payable_line,
      payment_method: acknowledgement.payment_method,
      payment_reference: acknowledgement.payment_reference,
      payment_effective_on: acknowledgement.payment_effective_on&.iso8601,
      metadata: {
        company_id: import.pay_period.company_id,
        pay_period_start: import.pay_period.start_date.iso8601,
        pay_period_end: import.pay_period.end_date.iso8601,
        pay_date: import.pay_period.pay_date.iso8601
      }.merge(acknowledgement.cancellation_metadata.symbolize_keys)
    )
    acknowledgement.mark_delivered!(at: Time.current)
  rescue TimeTracking::Client::Error => e
    acknowledgement&.record_delivery_failure!(e.message)
    raise
  end
end
