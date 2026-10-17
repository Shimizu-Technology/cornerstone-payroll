# frozen_string_literal: true

# Read-only delivery evidence for cancelled instruments, independent of how a
# later payment was made. A newer check event never hides an older pending sync.
class PaymentCancellationSyncState
  def self.for(item)
    new(item).call
  end

  def initialize(item)
    @item = item
  end

  def call
    events = item.check_events.select do |event|
      event.event_type == "voided" && event.details.is_a?(Hash) && event.details["payment_delivery_change"] == true &&
        event.details["original_check_cancelled"] == true
    end.index_by(&:id)
    records = direct_records(events) + manual_records(events.transform_keys(&:to_s))
    return if records.empty?

    pending = records.select { |record| record[:pending] }
    relevant_ids = pending.any? ? pending.map { |record| record[:event_id] } : [ records.map { |record| record[:event_id] }.max ]
    records = records.select { |record| relevant_ids.include?(record[:event_id]) }
    pending = records.select { |record| record[:pending] }
    failed = pending.select { |record| record[:error].present? }
    {
      status: pending.empty? ? "acknowledged" : failed.any? ? "error" : "pending",
      pending_count: pending.size,
      acknowledged_count: records.size - pending.size,
      oldest_pending_at: pending.map { |record| record[:occurred_at] }.min&.iso8601,
      errors: failed.map { |record| record[:error] }.uniq,
      hours_reserved: pending.any? && !item.voided?
    }
  end

  private

  attr_reader :item

  def direct_records(events)
    item.aire_payroll_entry_acknowledgements.filter_map do |ack|
      event = events[ack.check_event_id]
      next unless event && ack.status == "payment_cancelled"

      { event_id: event.id, occurred_at: event.created_at, pending: ack.delivered_at.nil?,
        error: ack.delivered_at.nil? ? ack.last_error : nil }
    end
  end

  def manual_records(events)
    item.time_tracking_manual_allocations.flat_map do |allocation|
      records = Array(allocation.payment_cancellation_receipts).filter_map do |receipt|
        next unless receipt.is_a?(Hash)

        event = events[receipt["check_event_id"].to_s]
        next unless event && receipt["acknowledged_at"].present?

        { event_id: event.id, occurred_at: event.created_at, pending: false, error: nil }
      end.index_by { |record| record[:event_id] }
      intent = allocation.payment_cancellation_intent
      event = events[intent["check_event_id"].to_s] if intent.is_a?(Hash)
      if event
        records[event.id] = { event_id: event.id, occurred_at: event.created_at, pending: true, error: allocation.last_sync_error }
      end
      records.values
    end
  end
end
