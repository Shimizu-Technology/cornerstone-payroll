# frozen_string_literal: true

module AirePayrollCalendar
  class Presenter
    def self.call(pay_period, now: Time.current)
      new(pay_period, now: now).call
    end

    def initialize(pay_period, now:)
      @pay_period = pay_period
      @now = now
    end

    def call
      calendar_period = @pay_period.aire_payroll_calendar_period
      @source = calendar_period&.time_tracking_source ||
               @pay_period.company.time_tracking_sources.active.find { |candidate| candidate.supports?(:payroll_calendar_v2) }
      return nil unless @source

      publication = calendar_period&.latest_publication
      event = calendar_period&.payroll_events&.order(occurred_at: :desc, id: :desc)&.first
      desired = desired_contract
      needs_revision = publication.present? && desired.present? &&
                       Contract.comparable(publication.payload).slice(*desired.keys) != desired
      cutoff_at = desired&.fetch("cutoff_at", nil) || publication&.payload&.fetch("cutoff_at", nil)
      @lock_mode = publication&.payload&.fetch("lock_mode", nil) || desired&.fetch("lock_mode", nil) || "scheduled"
      missed_unpublished_cutoff = @lock_mode != "manual" && publication.nil? && cutoff_at.present? && Time.iso8601(cutoff_at) <= @now

      {
        connected_payroll: ConnectedPayrollMode.capability,
        enabled: true,
        source_id: @source.id,
        source_name: @source.name,
        source_capabilities: @source.connector.capabilities,
        eligible: desired.present? && !missed_unpublished_cutoff,
        eligibility_error: eligibility_error(missed_unpublished_cutoff),
        eligibility_code: eligibility_code(missed_unpublished_cutoff),
        external_pay_period_id: calendar_period&.external_pay_period_id,
        cutoff_at: cutoff_at,
        lock_mode: @lock_mode,
        cutoff_enforcement_starts_on: @source.cutoff_enforcement_starts_on&.iso8601,
        next_scheduled_cutoff_at: current_source_state["next_scheduled_cutoff_at"],
        next_scheduled_cutoff_status: current_source_state.fetch("status", "unavailable"),
        next_scheduled_cutoff_refreshed_at: current_source_state["refreshed_at"],
        cutoff_state: cutoff_state(publication, event, cutoff_at, needs_revision),
        needs_revision: needs_revision,
        can_publish: ConnectedPayrollMode.enabled? && desired.present? && !missed_unpublished_cutoff && can_publish?(publication, cutoff_at),
        can_retry: ConnectedPayrollMode.enabled? && publication.present? && publication.delivery_status == "failed",
        publication: serialize_publication(publication),
        finalized_batch: serialize_event(event),
        cutoff_source: desired&.fetch("cutoff_source", nil) || Contract.comparable(publication&.payload || {})["cutoff_source"],
        policy_cutoff_at: policy_cutoff_at(desired, publication),
        cutoff_override: serialize_override(current_override),
        cutoff_history: cutoff_history,
        applied_cutoff_at: applied_publication(calendar_period)&.payload&.fetch("cutoff_at", nil),
        applied_cutoff_override: serialize_applied_override(applied_publication(calendar_period)),
        cutoff_delivery: serialize_delivery(calendar_period, event),
        cutoff_control: cutoff_control(calendar_period, publication, event, desired)
      }
    end

    private

    def current_override
      return @current_override if defined?(@current_override)

      @current_override = AirePayrollCutoffOverride.current_for(@pay_period)
    end

    def policy_cutoff_at(desired, publication)
      return desired["policy_cutoff_at"] || desired["cutoff_at"] if desired

      payload = publication&.payload || {}
      payload["policy_cutoff_at"] || payload["cutoff_at"]
    end

    def applied_publication(calendar_period)
      return @applied_publication if defined?(@applied_publication)

      @applied_publication = calendar_period&.latest_delivered_publication
    end

    # Who changed the lock AIRE is running on, from the delivered payload.
    def serialize_applied_override(publication)
      details = publication&.payload&.fetch("cutoff_override", nil)
      return nil unless details.is_a?(Hash)

      {
        action: details["action"],
        reason: details["reason"],
        set_by_name: details.dig("set_by", "name"),
        requested_via: details.dig("set_by", "system"),
        policy_cutoff_at: publication.payload["policy_cutoff_at"]
      }
    end

    # A newer version AIRE has not applied yet: on its way, refused, or expired
    # undelivered. Nothing once time tracking locked the period.
    def serialize_delivery(calendar_period, event)
      publication = calendar_period&.undelivered_publication
      return nil unless publication
      return nil if event || CutoffChange.finalized_import?(@pay_period, calendar_period.time_tracking_source)

      {
        state: delivery_state(publication),
        schedule_version: publication.schedule_version,
        cutoff_at: publication.payload["cutoff_at"],
        cutoff_source: Contract.comparable(publication.payload)["cutoff_source"],
        action: publication.payload.dig("cutoff_override", "action"),
        error: publication.rejection_message,
        last_delivery_attempt_at: publication.last_delivery_attempt_at
      }
    end

    def delivery_state(publication)
      return "rejected" if publication.rejected?

      publication.expired?(@now) ? "expired" : "pending"
    end

    # State only; the caller's permission is checked by the browser capability
    # and again by CutoffChange, whose rules this mirrors.
    def cutoff_control(calendar_period, publication, event, desired)
      bounds = CutoffChange.bounds(@pay_period, now: @now)
      reason = cutoff_unavailable_reason(calendar_period, publication, event, bounds)
      available = reason.nil?
      policy = policy_cutoff_at(desired, publication)
      {
        available: available,
        lock_now_available: available && @now >= bounds[:lock_now_available_at],
        reset_available: available && current_override.present? && policy.present? && Time.iso8601(policy) >= @now + CutoffChange::MIN_LEAD,
        earliest_at: bounds[:earliest_at].iso8601,
        latest_at: bounds[:latest_at].iso8601,
        lock_now_available_at: bounds[:lock_now_available_at].iso8601,
        unavailable_reason: reason
      }
    end

    def cutoff_unavailable_reason(calendar_period, publication, event, bounds)
      return "Connected payroll is paused" unless ConnectedPayrollMode.enabled?
      return "Publish this period to time tracking first" unless calendar_period && publication
      return "This period locks manually" if @lock_mode == "manual"
      if event || CutoffChange.finalized_import?(@pay_period, calendar_period.time_tracking_source)
        return "Time tracking already locked this period"
      end
      applied = applied_publication(calendar_period)
      return "Waiting for AIRE to confirm this period's schedule" unless applied
      return "This period's lock time has passed" if applied.cutoff_at <= @now
      return "AIRE locks this period in under 15 minutes, so the lock time can no longer change" if applied.cutoff_at < @now + CutoffChange::MIN_LEAD
      undelivered = calendar_period.undelivered_publication
      return "Waiting for AIRE to confirm the last change" if undelivered && !undelivered.supersedable?(@now)
      return "It is too close to payday to change the lock time" if bounds[:latest_at] <= @now

      nil
    end

    def serialize_override(override)
      return nil unless override

      {
        override_id: override.override_id,
        action: override.action,
        reason: override.reason,
        set_at: override.created_at,
        set_by_name: override.set_by_name,
        requested_via: override.requested_via,
        previous_cutoff_at: override.previous_cutoff_at
      }
    end

    def cutoff_history
      AirePayrollCutoffOverride.where(pay_period_id: @pay_period.id).includes(:set_by).newest_first.limit(5).map do |override|
        serialize_override(override).merge(cutoff_at: override.cutoff_at)
      end
    end

    def desired_contract
      return @desired_contract if defined?(@desired_contract)

      @desired_contract = @source.connector.calendar_contract(@pay_period).payload
    rescue Contract::Error => e
      @eligibility_error = e.message
      @eligibility_code = e.code
      @desired_contract = nil
    rescue ArgumentError => e
      @eligibility_error = e.message
      @eligibility_code = "source_capability_unavailable"
      @desired_contract = nil
    end

    def can_publish?(publication, cutoff_at)
      return true unless publication&.delivered?
      return true if publication.payload.slice("start_date", "end_date", "pay_date", "cutoff_at") ==
                     desired_contract.slice("start_date", "end_date", "pay_date", "cutoff_at")

      publication.cutoff_at > @now && Time.iso8601(cutoff_at) > @now
    end

    def cutoff_state(publication, event, cutoff_at, needs_revision)
      return @lock_mode != "manual" && cutoff_at && Time.iso8601(cutoff_at) <= @now ? "cutoff_due" : "unpublished" unless publication
      return "publication_failed" if publication.delivery_status == "failed"
      return "publishing" unless publication.delivered?
      return "schedule_changed" if needs_revision
      return "batch_verified" if event&.verified?
      return "batch_rejected" if event&.verification_status == "rejected"
      return "batch_verification_failed" if event&.verification_status == "failed"
      return "batch_verifying" if event

      source_state = publication.source_state
      captured_state = source_state["cutoff_state"]
      if @lock_mode != "manual" && (captured_state.blank? || %w[upcoming scheduled].include?(captured_state)) && cutoff_at && Time.iso8601(cutoff_at) <= @now
        return "cutoff_due"
      end
      return "manual" if @lock_mode == "manual" && captured_state != "finalized"
      return captured_state if captured_state.present?

      "scheduled"
    end

    def current_source_state
      @current_source_state ||= @source.reload.payroll_calendar_source_state
    end

    def eligibility_error(missed_unpublished_cutoff)
      return @eligibility_error if @eligibility_error
      return unless missed_unpublished_cutoff

      "This period's time-tracking cutoff passed before it was published. Create a correction or supplemental run instead."
    end

    def eligibility_code(missed_unpublished_cutoff)
      return @eligibility_code if @eligibility_code

      "cutoff_passed" if missed_unpublished_cutoff
    end

    def serialize_publication(publication)
      return nil unless publication

      {
        id: publication.id,
        schedule_version: publication.schedule_version,
        publication_id: publication.publication_id,
        delivery_status: publication.delivery_status,
        delivery_attempts: publication.delivery_attempts,
        delivered_at: publication.delivered_at,
        last_delivery_attempt_at: publication.last_delivery_attempt_at,
        next_delivery_attempt_at: publication.next_delivery_attempt_at,
        last_response_status: publication.last_response_status,
        last_error: publication.last_error,
        source_state: publication.source_state
      }
    end

    def serialize_event(event)
      return nil unless event

      payload = event.payload.fetch("payroll_batch")
      {
        event_id: event.event_id,
        verification_status: event.verification_status,
        verification_attempts: event.verification_attempts,
        occurred_at: event.occurred_at,
        verified_at: event.verified_at,
        last_error: event.last_error,
        payroll_batch_id: event.payroll_batch_id,
        payroll_batch_checksum: event.payroll_batch_checksum,
        finalized_at: payload["finalized_at"],
        summary: payload["summary"],
        issues: payload["issues"]
      }
    end
  end
end
