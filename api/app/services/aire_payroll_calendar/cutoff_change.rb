# frozen_string_literal: true

module AirePayrollCalendar
  # Lock now, change, or reset an AIRE pay period's lock time. The change is
  # recorded on Cornerstone's pay period (the source of truth), audited, and
  # republished to AIRE as the next schedule version in one transaction.
  #
  # Bounds (Pacific/Guam):
  # - lock now: only after the period's last day, and only while the current
  #   lock time is still ahead;
  # - change: a future time no earlier than the start of the day after the
  #   period ends and no later than 11:59 PM two days before payday;
  # - reset: back to the policy cutoff, while that time is still ahead.
  class CutoffChange
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: :unprocessable_entity)
        @status = status
        super(message)
      end
    end

    AIRE_ADMIN_ROLES = %w[owner admin].freeze

    Result = Data.define(:override, :publication, :idempotent)

    # Exactly one of actor (Cornerstone user) or source_actor (AIRE admin, with
    # the authenticated source) identifies who asked.
    def initialize(pay_period:, action:, reason:, actor: nil, source_actor: nil, source: nil,
                   cutoff_at: nil, request_id: nil, now: Time.current)
      @pay_period = pay_period
      @action = action.to_s
      @reason = reason.to_s.strip
      @actor = actor
      @source_actor = source_actor
      @source = source
      @requested_cutoff_at = cutoff_at
      @request_id = request_id.presence&.downcase
      @now = now
    end

    def call
      result = PayPeriod.transaction do
        @pay_period.lock!
        replay = replay_result
        next replay if replay

        authorize!
        calendar_period = @pay_period.aire_payroll_calendar_period
        raise Error, "Publish this pay period to time tracking before changing its lock time" unless calendar_period
        source = calendar_period.time_tracking_source
        raise Error.new("This request does not belong to this pay period's time tracking source", status: :forbidden) if @source && @source.id != source.id

        contract = source.connector.calendar_contract(@pay_period)
        current = contract.payload
        validate_state!(calendar_period, current)
        policy_cutoff_at = contract.policy_cutoff_at
        cutoff_at = target_cutoff_at(current, policy_cutoff_at)

        override = AirePayrollCutoffOverride.create!(
          company: @pay_period.company,
          pay_period: @pay_period,
          aire_payroll_calendar_period: calendar_period,
          action: @action,
          cutoff_at: cutoff_at,
          previous_cutoff_at: Time.iso8601(current.fetch("cutoff_at")),
          policy_cutoff_at: policy_cutoff_at,
          reason: @reason,
          requested_via: @source_actor ? "aire_services" : "cornerstone_payroll",
          set_by: @actor,
          source_actor: @source_actor,
          request_id: @request_id
        )
        publication = Publisher.new(
          pay_period: @pay_period, source: source, actor: @actor, now: @now, integration_authorized: @source_actor.present?
        ).publish!.publication
        record_audit!(override, publication)
        Result.new(override: override, publication: publication, idempotent: false)
      end
      Publisher.queue_delivery(result.publication.id, now: @now) unless result.idempotent
      result
    rescue Contract::Error, Publisher::Error => e
      raise Error.new(e.message, status: e.is_a?(Publisher::ConflictError) ? :conflict : :unprocessable_entity)
    rescue ActiveRecord::RecordNotUnique
      replay = PayPeriod.transaction { replay_result }
      return replay if replay

      raise Error.new("Another lock-time change won the concurrent update. Refresh and try again.", status: :conflict)
    end

    def self.bounds(pay_period, now: Time.current)
      earliest = Contract.earliest_override_at(pay_period)
      latest = Contract.latest_override_at(pay_period)
      { earliest_at: [ earliest, now ].max.in_time_zone(Contract::TIME_ZONE), latest_at: latest, lock_now_available_at: earliest }
    end

    private

    def replay_result
      return unless @request_id

      override = AirePayrollCutoffOverride.find_by(request_id: @request_id)
      return unless override
      unless override.pay_period_id == @pay_period.id && override.action == @action && override.reason == @reason
        raise Error.new("This request ID was already used for a different lock-time change", status: :conflict)
      end

      publication = override.aire_payroll_calendar_period.publications
        .find { |candidate| candidate.payload.dig("cutoff_override", "override_id") == override.override_id } ||
        override.aire_payroll_calendar_period.latest_publication
      Result.new(override: override, publication: publication, idempotent: true)
    end

    def authorize!
      raise Error, "Choose lock now, change, or reset" unless AirePayrollCutoffOverride::ACTIONS.include?(@action)
      raise Error, "Enter a reason for the change" if @reason.blank?
      raise Error, "Keep the reason under #{AirePayrollCutoffOverride::REASON_MAX} characters" if @reason.length > AirePayrollCutoffOverride::REASON_MAX

      if @source_actor
        raise Error.new("An authenticated time tracking source is required", status: :forbidden) unless @source&.active?
        unless AIRE_ADMIN_ROLES.include?(@source_actor["role"].to_s) && @source_actor["name"].to_s.strip.present? &&
               @source_actor["system"] == "aire_services"
          raise Error.new("Only AIRE owners and admins can change the lock time", status: :forbidden)
        end
      else
        company = @pay_period.company
        allowed = @actor && StaffRolePolicy.allowed?(@actor, :manage_time_tracking_lock, company: company) &&
                  @actor.payroll_access_allowed? && @actor.can_access_company?(company.id)
        raise Error.new(StaffRolePolicy.error_message(:manage_time_tracking_lock), status: :forbidden) unless allowed
      end
    end

    def validate_state!(calendar_period, current)
      raise Error, "Only scheduled locks can change their lock time" unless current.fetch("lock_mode", "scheduled") == "scheduled"
      if calendar_period.payroll_events.exists?
        raise Error.new("Time tracking already locked this period", status: :conflict)
      end
      latest = calendar_period.latest_publication
      current_cutoff = Time.iso8601(current.fetch("cutoff_at"))
      published_cutoff = latest&.cutoff_at
      if [ current_cutoff, published_cutoff ].compact.min <= @now
        raise Error.new("This period's lock time has already passed", status: :conflict)
      end
      raise Error, "It is too close to payday to change the lock time" if Contract.latest_override_at(@pay_period) <= @now
    end

    def target_cutoff_at(current, policy_cutoff_at)
      current_cutoff = Time.iso8601(current.fetch("cutoff_at"))
      case @action
      when "lock_now"
        earliest = Contract.earliest_override_at(@pay_period)
        if @now < earliest
          raise Error, "Lock now is available after the period ends (#{earliest.strftime('%b %-d')})"
        end

        @now.in_time_zone(Contract::TIME_ZONE).change(usec: 0)
      when "change"
        time = parse_time(@requested_cutoff_at)
        raise Error, "Choose a time after the period ends" if time < Contract.earliest_override_at(@pay_period)
        raise Error, "Choose a time at least two days before payday" if time > Contract.latest_override_at(@pay_period)
        raise Error, "Choose a time in the future" unless time > @now
        raise Error, "That is already the lock time" if time == current_cutoff

        time
      when "reset"
        raise Error, "This period already uses the default lock time" unless current["cutoff_source"] == "override"
        raise Error, "The default lock time has already passed. Use Lock now instead." unless policy_cutoff_at > @now

        policy_cutoff_at
      end
    end

    def parse_time(value)
      text = value.to_s
      raise Error, "Choose a new lock time" if text.blank?
      raise Error, "Choose a lock time with a time zone" unless text.match?(/(?:Z|[+-]\d{2}:\d{2})\z/i)

      Time.iso8601(text).in_time_zone(Contract::TIME_ZONE).change(sec: 0)
    rescue ArgumentError
      raise Error, "Choose a valid lock time"
    end

    def guam(time)
      time.in_time_zone(Contract::TIME_ZONE).iso8601
    end

    def record_audit!(override, publication)
      AuditLog.record!(
        user: @actor,
        company_id: @pay_period.company_id,
        action: "aire_payroll_calendar#cutoff_changed",
        record_type: "AirePayrollCutoffOverride",
        record_id: override.id,
        subject_name: "Time tracking lock time for #{@pay_period.start_date.iso8601} to #{@pay_period.end_date.iso8601}",
        event_category: "payroll",
        metadata: {
          pay_period_id: @pay_period.id,
          external_pay_period_id: override.aire_payroll_calendar_period.external_pay_period_id,
          override_id: override.override_id,
          change: override.action,
          cutoff_at: guam(override.cutoff_at),
          previous_cutoff_at: guam(override.previous_cutoff_at),
          policy_cutoff_at: guam(override.policy_cutoff_at),
          reason: override.reason,
          requested_via: override.requested_via,
          source_actor: override.source_actor,
          request_id: override.request_id,
          schedule_version: publication.schedule_version,
          publication_id: publication.publication_id
        }.compact
      )
    end
  end
end
