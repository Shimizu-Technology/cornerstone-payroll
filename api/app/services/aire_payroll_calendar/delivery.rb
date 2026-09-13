# frozen_string_literal: true

module AirePayrollCalendar
  class Delivery
    RETRY_DELAYS = [ 1.minute, 5.minutes, 15.minutes, 30.minutes, 1.hour, 6.hours ].freeze

    def initialize(publication_id:, now: Time.current, client_factory: nil)
      @publication_id = publication_id
      @now = now
      @client_factory = client_factory || ->(source) { TimeTracking::Client.new(source) }
    end

    def call
      publication = claim!
      return publication if publication.is_a?(Hash)

      period = publication.aire_payroll_calendar_period
      response = @client_factory.call(period.time_tracking_source).publish_payroll_calendar_period(
        external_pay_period_id: period.external_pay_period_id,
        payload: publication.payload,
        idempotency_key: publication.publication_id
      )
      source_state = response.fetch("payroll_calendar_period")
      validate_response!(period, publication, source_state)
      mark_delivered!(publication, source_state)
    rescue StandardError => e
      mark_failed!(e) if @attempt_claimed
      { publication_id: @publication_id, status: "failed", error: safe_error(e) }
    end

    private

    def claim!
      AirePayrollCalendarPublication.transaction do
        publication = AirePayrollCalendarPublication.lock.includes(
          aire_payroll_calendar_period: :time_tracking_source
        ).find(@publication_id)
        return { publication_id: publication.id, status: "delivered" } if publication.delivered?
        return { publication_id: publication.id, status: "skipped" } if publication.next_delivery_attempt_at&.>(@now)

        publication.update!(
          delivery_attempts: publication.delivery_attempts + 1,
          delivery_enqueued_until: nil,
          last_delivery_attempt_at: @now,
          next_delivery_attempt_at: @now + 1.minute
        )
        @attempt_claimed = true
        publication
      end
    end

    def validate_response!(period, publication, source_state)
      expected = publication.payload
      unless source_state.is_a?(Hash) &&
             source_state["external_pay_period_id"] == period.external_pay_period_id &&
             source_state["schedule_version"].to_i == publication.schedule_version &&
             source_state["publication_id"] == publication.publication_id &&
             source_state.values_at("start_date", "end_date", "pay_date") ==
               expected.values_at("start_date", "end_date", "pay_date") &&
             same_instant?(source_state["cutoff_at"], expected["cutoff_at"])
        raise TimeTracking::Client::Error, "AIRE returned calendar state that does not match this publication"
      end
    end

    def same_instant?(left, right)
      Time.iso8601(left.to_s) == Time.iso8601(right.to_s)
    rescue ArgumentError
      false
    end

    def mark_delivered!(publication, source_state)
      publication.with_lock do
        return { publication_id: publication.id, status: "delivered" } if publication.delivered?

        publication.update!(
          delivery_status: "delivered",
          delivery_enqueued_until: nil,
          next_delivery_attempt_at: nil,
          delivered_at: @now,
          last_response_status: nil,
          last_error: nil,
          source_state: source_state
        )
      end
      { publication_id: publication.id, status: "delivered" }
    end

    def mark_failed!(error)
      AirePayrollCalendarPublication.transaction(requires_new: true) do
        publication = AirePayrollCalendarPublication.lock.find(@publication_id)
        return if publication.delivered?

        delay = RETRY_DELAYS.fetch([ publication.delivery_attempts - 1, RETRY_DELAYS.length - 1 ].min)
        publication.update!(
          delivery_status: "failed",
          delivery_enqueued_until: nil,
          next_delivery_attempt_at: publication.cutoff_at <= @now ? nil : @now + delay,
          last_response_status: error.respond_to?(:response_status) ? error.response_status : nil,
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
