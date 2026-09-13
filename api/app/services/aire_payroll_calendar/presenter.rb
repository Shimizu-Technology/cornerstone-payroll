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
      source = @pay_period.company.time_tracking_sources.active.find_by(source_type: "aire_services")
      return nil unless source

      calendar_period = @pay_period.aire_payroll_calendar_period
      publication = calendar_period&.latest_publication
      event = calendar_period&.payroll_events&.order(occurred_at: :desc, id: :desc)&.first
      desired = desired_contract
      needs_revision = publication.present? && desired.present? &&
                       publication.payload.slice(*desired.keys) != desired
      cutoff_at = desired&.fetch("cutoff_at", nil) || publication&.payload&.fetch("cutoff_at", nil)
      missed_unpublished_cutoff = publication.nil? && cutoff_at.present? && Time.iso8601(cutoff_at) <= @now

      {
        enabled: true,
        source_id: source.id,
        source_name: source.name,
        eligible: desired.present? && !missed_unpublished_cutoff,
        eligibility_error: eligibility_error(missed_unpublished_cutoff),
        external_pay_period_id: calendar_period&.external_pay_period_id,
        cutoff_at: cutoff_at,
        cutoff_state: cutoff_state(publication, event, cutoff_at, needs_revision),
        needs_revision: needs_revision,
        can_publish: desired.present? && !missed_unpublished_cutoff && can_publish?(publication, cutoff_at),
        can_retry: publication.present? && publication.delivery_status == "failed",
        publication: serialize_publication(publication),
        finalized_batch: serialize_event(event)
      }
    end

    private

    def desired_contract
      return @desired_contract if defined?(@desired_contract)

      @desired_contract = Contract.new(@pay_period).payload
    rescue Contract::Error => e
      @eligibility_error = e.message
      @desired_contract = nil
    end

    def can_publish?(publication, cutoff_at)
      return true unless publication&.delivered?
      return true if publication.payload.slice("start_date", "end_date", "pay_date", "cutoff_at") ==
                     desired_contract.slice("start_date", "end_date", "pay_date", "cutoff_at")

      publication.cutoff_at > @now && Time.iso8601(cutoff_at) > @now
    end

    def cutoff_state(publication, event, cutoff_at, needs_revision)
      return cutoff_at && Time.iso8601(cutoff_at) <= @now ? "cutoff_due" : "unpublished" unless publication
      return "publication_failed" if publication.delivery_status == "failed"
      return "publishing" unless publication.delivered?
      return "schedule_changed" if needs_revision
      return "batch_verified" if event&.verified?
      return "batch_rejected" if event&.verification_status == "rejected"
      return "batch_verification_failed" if event&.verification_status == "failed"
      return "batch_verifying" if event

      source_state = publication.source_state
      return source_state["cutoff_state"] if source_state["cutoff_state"].present?
      return "cutoff_due" if cutoff_at && Time.iso8601(cutoff_at) <= @now

      "scheduled"
    end

    def eligibility_error(missed_unpublished_cutoff)
      return @eligibility_error if @eligibility_error
      return unless missed_unpublished_cutoff

      "This period's seven-day cutoff passed before it was published. Create a correction or supplemental run instead."
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
