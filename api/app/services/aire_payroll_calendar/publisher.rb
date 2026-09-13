# frozen_string_literal: true

module AirePayrollCalendar
  class Publisher
    class Error < StandardError; end
    class ConflictError < Error; end

    Result = Data.define(:calendar_period, :publication, :created)

    def initialize(pay_period:, source:, actor:, now: Time.current)
      @pay_period = pay_period
      @source = source
      @actor = actor
      @now = now
    end

    def call
      result = publish_transaction!
      queue_delivery(result.publication.id) if result.created
      result
    end

    private

    def queue_delivery(publication_id)
      AirePayrollCalendarPublication.dispatch_one!(publication_id, now: @now)
    rescue StandardError => e
      Rails.logger.error("AIRE calendar publication was retained but could not be queued: #{e.class}: #{e.message}")
    end

    def publish_transaction!
      conflict_attempts = 0

      begin
        PayPeriod.transaction do
          @pay_period.lock!
          @source.lock!
          validate_source!
          Contract.new(@pay_period).validate!

          calendar_period = find_or_create_calendar_period!
          latest = calendar_period.publications.lock.order(schedule_version: :desc).first
          contract_fields = Contract.new(@pay_period).payload

          if latest && same_contract?(latest.payload, contract_fields)
            return Result.new(calendar_period: calendar_period, publication: latest, created: false)
          end
          if Time.iso8601(contract_fields.fetch("cutoff_at")) <= @now
            raise ConflictError, "This period's AIRE cutoff has already passed. Create a correction or supplemental run instead."
          end
          if latest && latest.delivered? && latest.cutoff_at <= @now
            raise ConflictError, "This AIRE cutoff has passed, so its published dates cannot be changed. Create a correction or supplemental run instead."
          end

          version = latest ? latest.schedule_version + 1 : 1
          publication_id = SecureRandom.uuid
          payload = contract_fields.merge(
            "schedule_version" => version,
            "publication_id" => publication_id
          )
          publication = calendar_period.publications.create!(
            created_by: @actor,
            schedule_version: version,
            publication_id: publication_id,
            payload: payload,
            payload_checksum: TimeTracking::CanonicalPayload.checksum(payload),
            next_delivery_attempt_at: @now
          )
          record_audit!(calendar_period, publication)

          Result.new(calendar_period: calendar_period, publication: publication, created: true)
        end
      rescue ActiveRecord::RecordNotUnique
        conflict_attempts += 1
        retry if conflict_attempts < 2

        raise ConflictError, "Another calendar publication won the concurrent update. Refresh and try again."
      end
    end

    def validate_source!
      raise Error, "This client does not have an active AIRE Services source" unless @source.active? && @source.source_type == "aire_services"
      raise Error, "The AIRE source does not belong to this client" unless @source.company_id == @pay_period.company_id
    end

    def find_or_create_calendar_period!
      AirePayrollCalendarPeriod.find_or_create_by!(
        pay_period: @pay_period,
        time_tracking_source: @source
      ) do |period|
        period.company = @pay_period.company
      end
    end

    def same_contract?(payload, contract_fields)
      payload.slice(*contract_fields.keys) == contract_fields
    end

    def record_audit!(calendar_period, publication)
      AuditLog.record!(
        user: @actor,
        company_id: @pay_period.company_id,
        action: "aire_payroll_calendar#published",
        record_type: "AirePayrollCalendarPublication",
        record_id: publication.id,
        subject_name: "AIRE payroll calendar #{calendar_period.external_pay_period_id}",
        event_category: "payroll",
        metadata: {
          pay_period_id: @pay_period.id,
          external_pay_period_id: calendar_period.external_pay_period_id,
          schedule_version: publication.schedule_version,
          publication_id: publication.publication_id,
          cutoff_at: publication.payload.fetch("cutoff_at")
        }
      )
    end
  end
end
