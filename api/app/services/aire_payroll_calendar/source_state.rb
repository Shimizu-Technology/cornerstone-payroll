# frozen_string_literal: true

module AirePayrollCalendar
  # Mutable source-wide observations; publication delivery snapshots remain evidence.
  class SourceState
    def initialize(source, client_factory: nil)
      @source = source
      @client_factory = client_factory || ->(source) { TimeTracking::Client.new(source) }
    end

    def invalidate
      @source.with_lock { unavailable }
    end

    def refresh
      @source.with_lock do
        publication = AirePayrollCalendarPublication.joins(aire_payroll_calendar_period: :pay_period)
          .where(aire_payroll_calendar_periods: { time_tracking_source_id: @source.id })
          .where(delivery_status: "delivered")
          .order(Arel.sql("pay_periods.start_date DESC NULLS LAST, pay_periods.end_date DESC NULLS LAST, " \
            "pay_periods.pay_date DESC NULLS LAST, pay_periods.id DESC, " \
            "aire_payroll_calendar_publications.schedule_version DESC, aire_payroll_calendar_publications.id DESC"))
          .first
        raise TimeTracking::Client::Error, "No delivered calendar to refresh" unless publication

        period = publication.aire_payroll_calendar_period
        # GET returns the contract itself; only PUT wraps payroll_calendar_period.
        state = @client_factory.call(@source).payroll_calendar_period(external_pay_period_id: period.external_pay_period_id)
        unless state.is_a?(Hash) && state["external_pay_period_id"] == period.external_pay_period_id &&
               state["publication_id"] == publication.publication_id && state["schedule_version"] == publication.schedule_version
          raise TimeTracking::Client::Error, "AIRE returned an unexpected calendar revision"
        end
        record(state)
      rescue TimeTracking::Client::Error, KeyError, ArgumentError
        unavailable
      end
    end

    # Call while holding the source lock through the publication request, so an
    # older PUT response cannot overwrite a newer refresh or finalization.
    def record(state)
      raise TimeTracking::Client::Error, "AIRE did not report its next scheduled cutoff" unless state.key?("next_scheduled_cutoff_at")

      cutoff = state["next_scheduled_cutoff_at"]
      instant = Time.iso8601(cutoff) unless cutoff.nil?
      if instant && finalized_cutoffs.any? { |value| Time.iso8601(value) == instant }
        raise TimeTracking::Client::Error, "AIRE's next cutoff still refers to a finalized period"
      end
      save("available", cutoff)
    rescue TimeTracking::Client::Error, ArgumentError, TypeError
      unavailable
    end

    private

    def finalized_cutoffs
      @source.aire_payroll_calendar_periods.joins(:payroll_events, :publications)
        .where("aire_payroll_calendar_publications.payload ->> 'lock_mode' IS DISTINCT FROM 'manual'")
        .pluck(Arel.sql("aire_payroll_calendar_publications.payload ->> 'cutoff_at'")).compact
    end

    def unavailable
      save("unavailable", nil)
    end

    def save(status, cutoff)
      # Observations must remain writable even when source configuration is no
      # longer valid (for example, after its host leaves the allowlist).
      @source.update_columns(payroll_calendar_source_state: {
        "status" => status, "next_scheduled_cutoff_at" => cutoff, "refreshed_at" => Time.current.iso8601(6)
      }, updated_at: Time.current)
      @source.payroll_calendar_source_state
    end
  end
end
