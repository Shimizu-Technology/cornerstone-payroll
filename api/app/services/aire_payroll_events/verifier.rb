# frozen_string_literal: true

module AirePayrollEvents
  class Verifier
    RETRY_DELAYS = [ 1.minute, 5.minutes, 15.minutes, 30.minutes, 1.hour, 6.hours ].freeze

    def initialize(event_id:, now: Time.current, client_factory: nil)
      @event_id = event_id
      @now = now
      @client_factory = client_factory || ->(source) { TimeTracking::Client.new(source) }
    end

    def call
      event = claim!
      return event if event.is_a?(Hash)

      calendar_period = event.aire_payroll_calendar_period
      payload = @client_factory.call(calendar_period.time_tracking_source).payroll_batch(batch_id: event.payroll_batch_id)
      TimeTracking::PayrollBatchPayloadValidator.new(
        payload: payload,
        start_date: calendar_period.pay_period.start_date,
        end_date: calendar_period.pay_period.end_date
      ).validate!
      validate_against_event!(event, payload)
      mark_verified!(event, payload)
    rescue TimeTracking::Client::Error => e
      mark_retryable_failure!(e) if @attempt_claimed
      { event_id: @event_id, status: "failed", error: safe_error(e) }
    rescue TimeTracking::PayrollBatchPayloadValidator::Error, ConflictError => e
      mark_rejected!(e) if @attempt_claimed
      { event_id: @event_id, status: "rejected", error: safe_error(e) }
    end

    private

    class ConflictError < StandardError; end

    def claim!
      AirePayrollEvent.transaction do
        event = AirePayrollEvent.lock.includes(
          aire_payroll_calendar_period: [ :pay_period, :time_tracking_source ]
        ).find(@event_id)
        return { event_id: event.id, status: "verified" } if event.verified?
        return { event_id: event.id, status: "rejected" } if event.verification_status == "rejected"
        return { event_id: event.id, status: "skipped" } if event.next_verification_attempt_at&.>(@now)

        event.update!(
          verification_attempts: event.verification_attempts + 1,
          verification_enqueued_until: nil,
          last_verification_attempt_at: @now,
          next_verification_attempt_at: @now + 1.minute
        )
        @attempt_claimed = true
        event
      end
    end

    def validate_against_event!(event, payload)
      source_event = event.payload.fetch("payroll_batch")
      actual_checksum = payload.dig("export", "checksum").to_s
      unless ActiveSupport::SecurityUtils.secure_compare(actual_checksum, event.payroll_batch_checksum)
        raise ConflictError, "AIRE batch checksum does not match the finalized event"
      end
      unless payload["batch_id"] == event.payroll_batch_id &&
             same_instant?(payload["cutoff_at"], source_event["cutoff_at"]) &&
             payload["summary"] == source_event["summary"] &&
             payload["issues"] == source_event["issues"]
        raise ConflictError, "AIRE batch details do not match the finalized event"
      end
    end

    def same_instant?(left, right)
      Time.iso8601(left.to_s) == Time.iso8601(right.to_s)
    rescue ArgumentError
      false
    end

    def mark_verified!(event, payload)
      event.with_lock do
        return { event_id: event.id, status: "verified" } if event.verified?

        event.update!(
          verification_status: "verified",
          verification_enqueued_until: nil,
          next_verification_attempt_at: nil,
          verified_at: @now,
          last_error: nil,
          verified_batch_summary: {
            "schema_version" => payload["schema_version"],
            "batch_id" => payload["batch_id"],
            "checksum" => payload.dig("export", "checksum"),
            "finalized_at" => payload.dig("export", "finalized_at"),
            "summary" => payload["summary"],
            "issues" => payload["issues"]
          }
        )
        event.aire_payroll_calendar_period.time_tracking_source.update!(last_synced_at: @now)
      end
      { event_id: event.id, status: "verified" }
    end

    def mark_retryable_failure!(error)
      update_failure!("failed", error, retry_at: true)
    end

    def mark_rejected!(error)
      update_failure!("rejected", error, retry_at: false)
    end

    def update_failure!(status, error, retry_at:)
      AirePayrollEvent.transaction(requires_new: true) do
        event = AirePayrollEvent.lock.find(@event_id)
        return if event.verified?

        delay = RETRY_DELAYS.fetch([ event.verification_attempts - 1, RETRY_DELAYS.length - 1 ].min)
        event.update!(
          verification_status: status,
          verification_enqueued_until: nil,
          next_verification_attempt_at: retry_at ? @now + delay : nil,
          last_error: safe_error(error)
        )
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def safe_error(error)
      "#{error.class}: #{error.message}".truncate(1_000)
    end
  end
end
