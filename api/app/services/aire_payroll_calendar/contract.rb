# frozen_string_literal: true

module AirePayrollCalendar
  class Contract
    SCHEMA_VERSION = "1.0"
    TIME_ZONE = "Pacific/Guam"
    CUTOFF_DAYS_BEFORE = CompanyPaySchedule::PAYROLL_CUTOFF_DAYS_BEFORE
    OVERTIME_POLICY = {
      "schema_version" => "2.0",
      "calculation" => "weekly_only",
      "weekly_threshold_hours" => 40.0,
      "workweek_start" => "sunday",
      "time_zone" => TIME_ZONE
    }.freeze

    class Error < StandardError
      attr_reader :code

      def initialize(message, code:)
        @code = code
        super(message)
      end
    end

    attr_reader :pay_period

    def initialize(pay_period)
      @pay_period = pay_period
    end

    def payload
      validate!
      schedule = pay_schedule
      previous_pay_date = previous_regular_pay_date if schedule.time_tracking_cutoff_rule == "after_previous_regular_payday"
      cutoff_date = if previous_pay_date
                      previous_pay_date + schedule.time_tracking_cutoff_days
      else
                      pay_period.pay_date - schedule.time_tracking_cutoff_days
      end
      cutoff_hour, cutoff_minute = schedule.payroll_cutoff_at_minutes.divmod(60)
      cutoff_at = Time.find_zone!(TIME_ZONE).local(
        cutoff_date.year,
        cutoff_date.month,
        cutoff_date.day,
        cutoff_hour,
        cutoff_minute
      )
      legacy_policy = schedule.time_tracking_cutoff_rule == "before_pay_date" && schedule.time_tracking_cutoff_days == CUTOFF_DAYS_BEFORE
      fields = {
        "schema_version" => legacy_policy ? SCHEMA_VERSION : "2.0",
        "start_date" => pay_period.start_date.iso8601,
        "end_date" => pay_period.end_date.iso8601,
        "pay_date" => pay_period.pay_date.iso8601,
        "cutoff_at" => cutoff_at.iso8601,
        "time_zone" => TIME_ZONE,
        "overtime_policy" => OVERTIME_POLICY.dup
      }
      if legacy_policy
        fields["cutoff_days_before"] = CUTOFF_DAYS_BEFORE
      else
        fields["cutoff_rule"] = schedule.time_tracking_cutoff_rule
        fields["cutoff_days"] = schedule.time_tracking_cutoff_days
        fields["previous_regular_pay_date"] = previous_pay_date.iso8601 if previous_pay_date
      end
      fields
    end

    def validate!
      fail_contract!("Only regular payroll runs can be published to AIRE", "unsupported_run") unless pay_period.regular_cycle? && pay_period.regular_run?
      unless confirmed_semimonthly_schedule?
        future_schedule = next_confirmed_semimonthly_schedule
        if future_schedule
          fail_contract!(
            "This pay period begins before the confirmed payroll setup takes effect on #{format_date(future_schedule.effective_on)}. " \
            "AIRE scheduling starts with a regular semimonthly period on or after that date.",
            "pay_schedule_not_effective"
          )
        end
        fail_contract!("Confirm a semimonthly pay schedule before publishing this period to AIRE.", "pay_schedule_confirmation_required")
      end
      unless pay_schedule.pay_date_rule == "semimonthly_15th_and_month_end" &&
             pay_schedule.time_tracking_cutoff_rule == "after_previous_regular_payday" &&
             pay_schedule.time_tracking_cutoff_days == 7 && pay_schedule.payroll_cutoff_at_minutes == 1_020
        fail_contract!("Confirm AIRE's fixed 15th/month-end paydays and seven days after the previous regular payday at 17:00 Guam", "cutoff_rule_invalid")
      end
      fail_contract!("AIRE payroll periods must be the 1st–15th or 16th–month end", "period_dates_invalid") unless semimonthly_dates?
      unless pay_period.pay_date == pay_schedule.scheduled_pay_date_for(pay_period.end_date)
        fail_contract!("Use the fixed regular scheduled payday before publishing to AIRE.", "pay_date_invalid")
      end
      previous_regular_pay_date if pay_schedule.time_tracking_cutoff_rule == "after_previous_regular_payday"
      if pay_schedule.time_tracking_cutoff_rule == "after_previous_regular_payday" &&
         previous_regular_pay_date + pay_schedule.time_tracking_cutoff_days >= pay_period.pay_date
        fail_contract!("The time-tracking lock must fall before this payroll's pay date.", "cutoff_after_payday")
      end
      workweek = pay_period.resolved_company_workweek
      fail_contract!("Confirm the legal overtime workweek before publishing this period", "workweek_confirmation_required") unless workweek&.confirmed?
      unless workweek.starts_on_weekday.zero? && workweek.starts_at_minutes.zero? && workweek.timezone == TIME_ZONE
        fail_contract!("AIRE currently supports a Sunday midnight Guam overtime workweek; resolve the workweek before publishing", "workweek_unsupported")
      end
      fail_contract!("The pay date must be after the period end", "pay_date_invalid") unless pay_period.pay_date > pay_period.end_date

      true
    end

    private

    def previous_regular_pay_date
      return @previous_regular_pay_date if defined?(@previous_regular_pay_date)

      candidates = PayPeriod.where(
        company_id: pay_period.company_id,
        end_date: pay_period.start_date - 1.day,
        cycle: "regular",
        run_purpose: "regular",
        correction_status: nil,
        parallel_run: false
      ).where.not(id: pay_period.id).limit(2).pluck(:pay_date)
      if candidates.length != 1
        fail_contract!("Enter the adjacent previous regular payroll period before publishing this calendar.", "previous_regular_payday_required")
      end
      date = candidates.first
      unless date && date < pay_period.pay_date
        fail_contract!("The previous regular payday must precede this payroll's pay date.", "previous_regular_payday_invalid")
      end
      unless date == pay_schedule.scheduled_pay_date_for(pay_period.start_date - 1.day)
        fail_contract!("The previous regular payday must use the fixed scheduled date.", "previous_regular_payday_invalid")
      end
      @previous_regular_pay_date = date
    end

    def confirmed_semimonthly_schedule?
      schedule = pay_schedule
      schedule&.confirmed? &&
        schedule.frequency == "semimonthly" &&
        schedule.period_rule == "semimonthly" &&
        schedule.timezone == TIME_ZONE &&
        schedule.effective_on <= pay_period.start_date &&
        (schedule.ends_on.nil? || schedule.ends_on >= pay_period.end_date)
    end

    def pay_schedule
      @pay_schedule ||= pay_period.company_pay_schedule || CompanyPaySchedule.for_date(pay_period.company_id, pay_period.start_date)
    end

    def next_confirmed_semimonthly_schedule
      pay_period.company.company_pay_schedules
                .where(confirmation_status: "confirmed", frequency: "semimonthly", period_rule: "semimonthly", timezone: TIME_ZONE)
                .where("effective_on > ?", pay_period.start_date)
                .order(:effective_on, :id)
                .first
    end

    def fail_contract!(message, code)
      raise Error.new(message, code: code)
    end

    def format_date(date)
      date.strftime("%B %-d, %Y")
    end

    def semimonthly_dates?
      first_half = pay_period.start_date.day == 1 && pay_period.end_date == Date.new(pay_period.start_date.year, pay_period.start_date.month, 15)
      second_half = pay_period.start_date.day == 16 && pay_period.end_date == pay_period.start_date.end_of_month
      first_half || second_half
    end
  end
end
