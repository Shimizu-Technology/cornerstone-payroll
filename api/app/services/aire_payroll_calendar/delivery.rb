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
      return { status: "paused" } unless ConnectedPayrollMode.enabled?
      return { publication_id: @publication_id, status: "quarantined" } if StagingQuarantine.suppressed?("aire_payroll_calendar_publications", @publication_id)
      publication = claim!
      return publication if publication.is_a?(Hash)

      period = publication.aire_payroll_calendar_period
      period.time_tracking_source.with_lock do
        # A lock-time change can replace this version after the claim and
        # before this lock; nothing can replace it while the lock is held.
        superseded = supersede_replaced!(publication.reload)
        next superseded if superseded

        response = @client_factory.call(period.time_tracking_source).publish_payroll_calendar_period(
          external_pay_period_id: period.external_pay_period_id,
          payload: publication.payload,
          idempotency_key: publication.publication_id
        )
        source_state = response.fetch("payroll_calendar_period")
        validate_response!(period, publication, source_state)
        result = mark_delivered!(publication, source_state)
        SourceState.new(period.time_tracking_source).record(source_state)
        result
      end
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
        superseded = supersede_replaced!(publication)
        return superseded if superseded

        unless publication.aire_payroll_calendar_period.time_tracking_source.historical_reconciliation_complete?
          publication.update!(
            delivery_enqueued_until: nil,
            next_delivery_attempt_at: retry_allowed?(publication) ? @now + 5.minutes : nil,
            last_error: "Historical payroll reconciliation approval is required before delivering this calendar"
          )
          return { publication_id: publication.id, status: "held" }
        end

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

    # Stops delivering a version a newer one replaces (see superseded_by).
    def supersede_replaced!(publication)
      newer = superseded_by(publication)
      return unless newer

      publication.update!(
        delivery_status: "failed",
        delivery_enqueued_until: nil,
        next_delivery_attempt_at: nil,
        last_error: "Superseded by schedule version #{newer.schedule_version}#{', which AIRE confirmed' if newer.delivered?}"
      )
      { publication_id: publication.id, status: "superseded" }
    end

    def validate_response!(period, publication, source_state)
      expected = publication.payload
      unless source_state.is_a?(Hash) &&
             source_state["external_pay_period_id"] == period.external_pay_period_id &&
             source_state["schedule_version"].to_i == publication.schedule_version &&
             source_state["publication_id"] == publication.publication_id &&
             source_state.values_at("start_date", "end_date", "pay_date") ==
               expected.values_at("start_date", "end_date", "pay_date") &&
             same_instant?(source_state["cutoff_at"], expected["cutoff_at"]) &&
             (!expected.key?("overtime_policy") || source_state["overtime_policy"] == expected["overtime_policy"]) &&
             %w[lock_mode cutoff_enforcement_starts_on].all? { |key| !expected.key?(key) || source_state[key] == expected[key] } &&
             override_applied?(source_state, expected)
        raise TimeTracking::Client::Error, "AIRE returned calendar state that does not match this publication"
      end
    end

    # A publication sent while AIRE could still accept it keeps retrying after
    # its cutoff: AIRE may have applied it and lost the response, and it
    # replays a known publication_id before any time check. Retries are only
    # scheduled past the cutoff for such a publication, so an earlier attempt
    # means one was in time. A first attempt after the cutoff could not have
    # been applied. Retrying stops when AIRE refuses it after the cutoff, or
    # once it is superseded (see superseded_by).
    def retry_allowed?(publication, rejected: publication.rejected?)
      return false if superseded_by(publication, rejected: rejected)
      return true if publication.payload["lock_mode"] == "manual" || publication.cutoff_at > @now ||
                     Publisher.lock_now_deliverable?(publication.payload, @now)

      publication.delivery_attempts > 1 && !rejected
    end

    # AIRE confirmed a newer version, or a newer version replaces one AIRE
    # refused or that is no longer scheduled. Publisher clears the schedule of
    # every older version a lock-time change replaces, so a nil schedule here
    # also covers a failure recorded after that change committed.
    def superseded_by(publication, rejected: publication.rejected?)
      newer = AirePayrollCalendarPublication
        .where(aire_payroll_calendar_period_id: publication.aire_payroll_calendar_period_id)
        .where("schedule_version > ?", publication.schedule_version)
        .order(schedule_version: :desc)
      confirmed = newer.find_by(delivery_status: "delivered")
      return confirmed if confirmed

      newer.first if rejected || publication.rejected? || publication.next_delivery_attempt_at.nil?
    end

    # An AIRE build without admin lock times would store the cutoff as policy.
    def override_applied?(source_state, expected)
      return true unless expected["cutoff_source"] == "override"

      source_state["cutoff_source"] == "override" &&
        source_state.dig("cutoff_override", "override_id") == expected.dig("cutoff_override", "override_id")
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
        status = error.respond_to?(:response_status) ? error.response_status : nil
        rejected = AirePayrollCalendarPublication::REJECTED_RESPONSE_STATUSES.include?(status)
        publication.update!(
          delivery_status: "failed",
          delivery_enqueued_until: nil,
          next_delivery_attempt_at: retry_allowed?(publication, rejected: rejected) ? @now + delay : nil,
          last_response_status: status,
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
