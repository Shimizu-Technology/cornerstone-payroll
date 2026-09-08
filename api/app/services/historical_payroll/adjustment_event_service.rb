# frozen_string_literal: true

module HistoricalPayroll
  class AdjustmentEventService
    OPERATOR_EVENT_TYPES = %w[
      filing_reviewed_no_amendment filing_amendment_required filing_amendment_filed_external
      filing_review_reopened downstream_impact_acknowledged
    ].freeze

    def initialize(adjustment:, actor:, event_type:, note: nil, metadata: {})
      @adjustment = adjustment
      @actor = actor
      @event_type = event_type.to_s
      @note = note
      @metadata = metadata.to_h
    end

    def call
      QuickbooksHistory::ClientBootstrapAuthorization.ensure_authorized!(actor: actor, company_id: adjustment.company_id)
      raise ArgumentError, "Unknown historical adjustment event" unless event_type.in?(OPERATOR_EVENT_TYPES)
      if event_type == "filing_amendment_filed_external" && adjustment.filing_review_state != "amendment_required"
        raise ArgumentError, "Record that an amendment is required before marking it filed externally"
      end

      HistoricalPaycheckAdjustmentEvent.transaction do
        event = adjustment.events.create!(
          company: adjustment.company,
          created_by: actor,
          event_type: event_type,
          note: note,
          metadata: metadata
        )
        AuditLog.record!(
          user: actor,
          organization_id: adjustment.company.organization_id,
          company_id: adjustment.company_id,
          action: "historical_paycheck_adjustments##{event_type}",
          record_type: "historical_paycheck_adjustment_events",
          record_id: event.id,
          subject_name: adjustment.historical_paycheck.source_employee_name,
          metadata: { historical_paycheck_adjustment_id: adjustment.id, filing_year: adjustment.filing_year, filing_quarter: adjustment.filing_quarter }
        )
        event
      end
    end

    private

    attr_reader :adjustment, :actor, :event_type, :note, :metadata
  end
end
