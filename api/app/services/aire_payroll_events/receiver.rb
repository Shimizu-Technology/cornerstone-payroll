# frozen_string_literal: true

module AirePayrollEvents
  class Receiver
    SCHEMA_VERSION = "1.0"

    class Error < StandardError; end
    class UnauthorizedError < Error; end
    class ConflictError < Error; end

    Result = Data.define(:event, :created)

    def initialize(payload:, shared_secret:, idempotency_key:, now: Time.current)
      @payload = payload
      @shared_secret = shared_secret.to_s
      @idempotency_key = idempotency_key.to_s.downcase
      @now = now
    end

    def call
      validate_shape!
      calendar_period = find_and_authenticate_period!
      publication = find_publication!(calendar_period)
      validate_contract!(calendar_period, publication)
      checksum = TimeTracking::CanonicalPayload.checksum(@payload)

      result = persist!(calendar_period, publication, checksum)
      queue_verification(result.event.id) if result.created
      result
    end

    private

    def queue_verification(event_id)
      AirePayrollEvent.dispatch_one!(event_id, now: @now)
    rescue StandardError => e
      Rails.logger.error("AIRE payroll event was retained but could not be queued: #{e.class}: #{e.message}")
    end

    def validate_shape!
      raise Error, "Event payload must be a JSON object" unless @payload.is_a?(Hash)
      raise Error, "Unsupported event schema version" unless @payload["schema_version"] == SCHEMA_VERSION
      raise Error, "Unsupported event source" unless @payload["source"] == "aire_services"
      raise Error, "Unsupported event type" unless @payload["event_type"] == AirePayrollEvent::EVENT_TYPE
      raise Error, "Idempotency-Key must match event_id" unless valid_uuid?(@idempotency_key) && @idempotency_key == @payload["event_id"].to_s.downcase
      @occurred_at = Time.iso8601(@payload.fetch("occurred_at").to_s)
      raise Error, "payroll_period is required" unless @payload["payroll_period"].is_a?(Hash)
      raise Error, "payroll_batch is required" unless @payload["payroll_batch"].is_a?(Hash)
    rescue KeyError, ArgumentError
      raise Error, "occurred_at must be a valid ISO timestamp"
    end

    def find_and_authenticate_period!
      external_id = @payload.dig("payroll_period", "external_pay_period_id").to_s.downcase
      calendar_period = AirePayrollCalendarPeriod.includes(:time_tracking_source).find_by(external_pay_period_id: external_id)
      raise UnauthorizedError, "Invalid AIRE integration credentials" unless calendar_period

      source = calendar_period.time_tracking_source
      raise UnauthorizedError, "Invalid AIRE integration credentials" unless source.active?

      expected = source.shared_secret.to_s
      authenticated = expected.present? && @shared_secret.present? &&
                      expected.bytesize == @shared_secret.bytesize &&
                      ActiveSupport::SecurityUtils.secure_compare(expected, @shared_secret)
      raise UnauthorizedError, "Invalid AIRE integration credentials" unless authenticated

      calendar_period
    end

    def find_publication!(calendar_period)
      source_period = @payload.fetch("payroll_period")
      publication = calendar_period.publications.find_by(
        schedule_version: source_period["schedule_version"],
        publication_id: source_period["publication_id"]
      )
      raise ConflictError, "AIRE finalized an unknown calendar revision" unless publication
      latest_delivered = calendar_period.publications.where(delivery_status: "delivered").order(schedule_version: :desc).first
      raise ConflictError, "AIRE finalized a calendar revision that Cornerstone did not confirm as delivered" unless publication == latest_delivered

      publication
    end

    def validate_contract!(calendar_period, publication)
      source_period = @payload.fetch("payroll_period")
      source_batch = @payload.fetch("payroll_batch")
      expected = publication.payload

      unless source_period.values_at("start_date", "end_date", "pay_date") ==
             expected.values_at("start_date", "end_date", "pay_date") &&
             same_instant?(source_period["cutoff_at"], expected["cutoff_at"])
        raise ConflictError, "AIRE finalized calendar dates that do not match the published revision"
      end
      unless source_period["external_pay_period_id"] == calendar_period.external_pay_period_id
        raise ConflictError, "AIRE finalized an unexpected calendar identity"
      end
      raise Error, "AIRE event must report a finalized period" unless source_period["status"] == "finalized"
      raise Error, "AIRE event payroll batch ID is required" if source_batch["id"].blank?
      raise Error, "AIRE event payroll batch schema version must be 2.0" unless source_batch["schema_version"] == "2.0"
      raise Error, "AIRE event payroll batch checksum is invalid" unless source_batch["checksum"].to_s.match?(/\A[0-9a-f]{64}\z/)
      unless source_batch.values_at("start_date", "end_date") ==
             expected.values_at("start_date", "end_date") &&
             same_instant?(source_batch["cutoff_at"], expected["cutoff_at"])
        raise ConflictError, "AIRE event payroll batch does not match the published period"
      end
      raise Error, "AIRE event payroll batch summary is required" unless source_batch["summary"].is_a?(Hash)
      raise Error, "AIRE event payroll batch issues are required" unless source_batch["issues"].is_a?(Hash)
    end

    def persist!(calendar_period, publication, checksum)
      event = AirePayrollEvent.find_by(event_id: @idempotency_key)
      return replay_result!(event, checksum) if event
      if AirePayrollEvent.exists?(
        time_tracking_source_id: calendar_period.time_tracking_source_id,
        payroll_batch_id: @payload.dig("payroll_batch", "id")
      )
        raise ConflictError, "This AIRE payroll batch was already finalized by another event"
      end

      created = AirePayrollEvent.create!(
        aire_payroll_calendar_period: calendar_period,
        aire_payroll_calendar_publication: publication,
        time_tracking_source: calendar_period.time_tracking_source,
        event_id: @idempotency_key,
        event_type: @payload.fetch("event_type"),
        occurred_at: @occurred_at,
        payload: @payload,
        payload_checksum: checksum,
        payroll_batch_id: @payload.dig("payroll_batch", "id"),
        payroll_batch_checksum: @payload.dig("payroll_batch", "checksum"),
        next_verification_attempt_at: @now
      )
      record_audit!(calendar_period, created)
      Result.new(event: created, created: true)
    rescue ActiveRecord::RecordNotUnique
      event = AirePayrollEvent.find_by(event_id: @idempotency_key)
      return replay_result!(event, checksum) if event

      raise ConflictError, "This AIRE payroll batch was already finalized by another event"
    end

    def replay_result!(event, checksum)
      unless ActiveSupport::SecurityUtils.secure_compare(event.payload_checksum, checksum)
        raise ConflictError, "event_id was already used for different contents"
      end

      Result.new(event: event, created: false)
    end

    def record_audit!(calendar_period, event)
      AuditLog.record!(
        user: nil,
        organization_id: calendar_period.company.organization_id,
        company_id: calendar_period.company_id,
        action: "aire_payroll_event#received",
        record_type: "AirePayrollEvent",
        record_id: event.id,
        subject_name: "AIRE finalized batch #{event.payroll_batch_id}",
        event_category: "integration",
        metadata: {
          event_id: event.event_id,
          external_pay_period_id: calendar_period.external_pay_period_id,
          pay_period_id: calendar_period.pay_period_id,
          payroll_batch_id: event.payroll_batch_id,
          payroll_batch_checksum: event.payroll_batch_checksum
        },
        ip_address: nil,
        user_agent: nil,
        request_id: nil
      )
    end

    def valid_uuid?(value)
      value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
    end

    def same_instant?(left, right)
      Time.iso8601(left.to_s) == Time.iso8601(right.to_s)
    rescue ArgumentError
      false
    end
  end
end
