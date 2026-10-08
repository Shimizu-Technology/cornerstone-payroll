# frozen_string_literal: true

module TimeTracking
  # Retiring an instrument keeps the earned payroll obligation and reserved hours.
  # The new operation must be explicitly pinned; the legacy AIRE profile never
  # grants it implicitly.
  class PaymentCancellationBridge
    # A session lock spans the short durable-intent transaction, remote command,
    # and local acknowledgement. Both native method changes and sync use it.
    # Row locks alone would roll back the command intent after remote success.
    def self.with_item_lock(item_id)
      ApplicationRecord.connection_pool.with_connection do |connection|
        key = 4_100_000_000_000_000_000 + Integer(item_id)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until connection.select_value("SELECT pg_try_advisory_lock(#{key})")
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise TimeTracking::Client::Error, "Another payment transition is in progress; refresh and retry"
          end
          sleep 0.05
        end
        begin
          yield
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{key})")
        end
      end
    end

    def self.blocker_for(item, check_activity: nil)
      return unless item.pay_period.committed?
      if item.source_accounting_correction_linked?
        return "This payment has an exact source accounting correction. Payment cancellation is held until its disposition and source receipt can be reversed together; review the linked correction with payroll support."
      end
      if item.time_tracking_manual_allocations.where.not(status: "voided").where.not(payment_cancellation_intent: {}).exists?
        return "Finish syncing the earlier check cancellation before changing this payment method again."
      end
      return unless item.effective_payment_delivery_method == "paper_check"

      check_activity = PayrollPaymentMethodEligibility.new(item).check_has_activity? if check_activity.nil?
      return unless check_activity

      direct = item.time_tracking_entry_allocations.to_a
      manual = item.time_tracking_manual_allocations.where.not(status: "voided").to_a
      sources = (direct + manual).map(&:time_tracking_source).uniq(&:id)
      return if sources.empty?
      if sources.any? { |source| !source.active? || !source.remote_identity_pinned? || !source.supports?(:payment_cancellation_v1) }
        return "The connected time source must verify payment cancellation support before retiring this check."
      end
      if direct.any? { |row| row.verified_source_user_uuid.blank? } || manual.any? { |row| row.source_user_uuid.blank? }
        return "Verify the connected employee identity before retiring this check."
      end
      if direct.any? { |row| !valid_original_receipt?(item, row) }
        return "The original check's exact source receipt is missing. Review the connected payment before cancelling it."
      end
      if manual.any? { |row| row.payment_cancellation_intent.present? }
        return "Finish syncing the earlier check cancellation before changing this payment method again."
      end
      nil
    end

    def self.original_receipt(item, row, number)
      AirePayrollEntryAcknowledgement.where(payroll_item_id: item.id,
        time_tracking_import_id: row.time_tracking_import_id,
        source_time_entry_id: row.source_time_entry_id, source_line_key: row.line_key,
        payment_method: "paper_check", payment_reference: number,
        status: %w[payment_prepared payment_issued]).order(:id).last
    end

    def self.valid_original_receipt?(item, row)
      receipt = original_receipt(item, row, item.check_number)
      receipt&.line_contract? && receipt.source_user_uuid == row.verified_source_user_uuid &&
        receipt.regular_hours == row.regular_hours && receipt.overtime_hours == row.overtime_hours &&
        receipt.total_hours == row.total_hours && receipt.source_kind == row.source_kind
    end

    def self.validate_original_receipts!(item)
      item.time_tracking_entry_allocations.each do |row|
        unless valid_original_receipt?(item, row)
          raise PayrollPaymentMethodService::Error, "The original check's exact source receipt is missing. Review the connected payment before cancelling it."
        end
      end
    end

    def self.record_manual_intents!(event)
      item = event.payroll_item
      delivery = item.check_events.deliveries.where(check_number: event.check_number).order(:id).last
      item.time_tracking_manual_allocations.where.not(status: "voided").find_each do |allocation|
        allocation.with_lock do
          raise PayrollPaymentMethodService::Error, "Finish syncing the earlier check cancellation first" if allocation.payment_cancellation_intent.present?
          allocation.update!(payment_cancellation_intent: {
            command_id: SecureRandom.uuid,
            check_event_id: event.id,
            occurred_at: event.created_at.iso8601(6), reason: event.reason,
            cancellation_evidence_reference: event.evidence_reference,
            payment_method: "paper_check", payment_reference: event.check_number,
            payment_effective_on: delivery&.effective_on&.iso8601
          }.compact)
        end
      end
    end
  end
end
