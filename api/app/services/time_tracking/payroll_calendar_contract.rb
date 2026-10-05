# frozen_string_literal: true

module TimeTracking
  class PayrollCalendarContract
    Error = AirePayrollCalendar::Contract::Error
    WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

    def initialize(pay_period)
      @period = pay_period
    end

    def payload
      validate!
      previous = previous_regular_payday if schedule.time_tracking_cutoff_rule == "after_previous_regular_payday"
      date = previous ? previous + schedule.time_tracking_cutoff_days : @period.pay_date - schedule.time_tracking_cutoff_days
      hour, minute = schedule.payroll_cutoff_at_minutes.divmod(60)
      cutoff = Time.find_zone!(schedule.timezone).local(date.year, date.month, date.day, hour, minute)
      fail!("The cutoff must precede the scheduled payday", "cutoff_after_payday") if cutoff.to_date >= @period.pay_date
      {
        "schema_version" => "2.0", "start_date" => @period.start_date.iso8601,
        "end_date" => @period.end_date.iso8601, "pay_date" => @period.pay_date.iso8601,
        "cutoff_at" => cutoff.iso8601, "time_zone" => schedule.timezone,
        "cutoff_rule" => schedule.time_tracking_cutoff_rule, "cutoff_days" => schedule.time_tracking_cutoff_days,
        "overtime_policy" => {
          "schema_version" => "2.0", "calculation" => "weekly_only", "weekly_threshold_hours" => 40.0,
          "workweek_start" => WEEKDAYS.fetch(workweek.starts_on_weekday), "time_zone" => workweek.timezone
        }
      }.tap { |fields| fields["previous_regular_pay_date"] = previous.iso8601 if previous }
    end

    def validate!
      fail!("Only regular payroll runs can publish a time calendar", "unsupported_run") unless @period.regular_cycle? && @period.regular_run?
      unless schedule&.confirmed? && schedule.effective_on <= @period.start_date && (schedule.ends_on.nil? || schedule.ends_on >= @period.end_date)
        fail!("Confirm the effective company pay schedule", "pay_schedule_confirmation_required")
      end
      unless workweek&.confirmed? && workweek.effective_on <= @period.start_date && (workweek.ends_on.nil? || workweek.ends_on >= @period.end_date)
        fail!("Confirm the effective legal overtime workweek", "workweek_confirmation_required")
      end
      unless workweek.starts_at_minutes.zero? && workweek.timezone == schedule.timezone && Time.find_zone(schedule.timezone)
        fail!("This protocol requires midnight workweeks in the company schedule timezone", "workweek_unsupported")
      end
      fail!("Confirm an automatic scheduled payday", "pay_date_invalid") unless schedule.scheduled_pay_date_for(@period.end_date) == @period.pay_date
      fail!("The scheduled payday must follow the work period", "pay_date_invalid") unless @period.pay_date > @period.end_date
      fail!("Work dates do not match the confirmed schedule", "period_dates_invalid") unless valid_dates?
      true
    end

    private

    def schedule
      @schedule ||= @period.company_pay_schedule || CompanyPaySchedule.for_date(@period.company_id, @period.start_date)
    end

    def workweek
      @workweek ||= @period.resolved_company_workweek
    end

    def previous_regular_payday
      candidates = PayPeriod.where(company_id: @period.company_id, end_date: @period.start_date - 1.day,
        cycle: "regular", run_purpose: "regular", correction_status: nil, parallel_run: false).where.not(id: @period.id).limit(2).pluck(:pay_date)
      date = candidates.one? ? candidates.first : nil
      unless date && date < @period.pay_date && date == schedule.scheduled_pay_date_for(@period.start_date - 1.day)
        fail!("Enter one adjacent previous regular period with its scheduled payday", "previous_regular_payday_required")
      end
      date
    end

    def valid_dates?
      case schedule.period_rule
      when "weekly"
        @period.start_date.wday == schedule.period_start_weekday && @period.end_date == @period.start_date + 6.days
      when "biweekly"
        @period.start_date.wday == schedule.period_start_weekday && schedule.period_anchor_date &&
          ((@period.start_date - schedule.period_anchor_date).to_i % 14).zero? && @period.end_date == @period.start_date + 13.days
      when "semimonthly"
        (@period.start_date.day == 1 && @period.end_date == @period.start_date.change(day: 15)) ||
          (@period.start_date.day == 16 && @period.end_date == @period.start_date.end_of_month)
      when "manual"
        @period.end_date >= @period.start_date
      else
        false
      end
    end

    def fail!(message, code)
      raise Error.new(message, code: code)
    end
  end
end
