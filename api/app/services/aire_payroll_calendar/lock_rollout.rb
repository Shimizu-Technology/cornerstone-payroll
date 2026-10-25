# frozen_string_literal: true

module AirePayrollCalendar
  class LockRollout
    class Error < StandardError; end

    def initialize(source:, starts_on:, actor:, reason:)
      @source = source
      @starts_on = Date.iso8601(starts_on.to_s)
      @actor = actor.to_s.strip
      @reason = reason.to_s.strip
    rescue Date::Error
      raise Error, "STARTS_ON must be an ISO date"
    end

    def configure!
      unless @source.source_type == "aire_services" && [ 1, 16 ].include?(@starts_on.day) && @actor.present? && @reason.present?
        raise Error, "An AIRE source, semimonthly STARTS_ON, ACTOR and REASON are required"
      end

      @source.with_lock do
        # Also protect an empty inventory from concurrent legacy writers. Old
        # publishers/delivery workers must remain quiesced after this transaction.
        ApplicationRecord.connection.execute("LOCK TABLE aire_payroll_calendar_periods, aire_payroll_calendar_publications IN SHARE MODE")
        unless @source.cutoff_enforcement_starts_on == @starts_on
          raise Error, "STARTS_ON must match the immutable configured boundary; a change requires a reviewed migration"
        end
        validate_inventory!
        AuditLog.create!(user: nil, actor_name: @actor, actor_role: "operator",
          company_id: @source.company_id, organization_id: @source.company.organization_id,
          action: "time_tracking_source#lock_rollout_gate_passed", record_type: "TimeTrackingSource", record_id: @source.id,
          event_category: "integration", metadata: { cutoff_enforcement_starts_on: @starts_on.iso8601, reason: @reason })
        { source_id: @source.id, cutoff_enforcement_starts_on: @starts_on.iso8601, status: "configured" }
      end
    end

    private

    def validate_inventory!
      @source.aire_payroll_calendar_periods.includes(:pay_period, :publications).each do |period|
        publications = period.publications
        if period.pay_period.start_date < @starts_on && publications.empty?
          raise Error, "Preactivation calendar #{period.id} has no explicit manual rollout publication"
        end
        publications.each do |publication|
          start_date = Date.iso8601(publication.payload.fetch("start_date"))
          next if start_date >= @starts_on && period.pay_period.start_date >= @starts_on
          next if publication.payload["lock_mode"] == "manual" &&
                  publication.payload["cutoff_enforcement_starts_on"] == @starts_on.iso8601

          raise Error, "Preactivation publication #{publication.id} lacks explicit manual mode and activation; resolve inventory before rollout"
        rescue KeyError, Date::Error
          raise Error, "Publication #{publication.id} has invalid period evidence; resolve inventory before rollout"
        end
      end
    end
  end
end
