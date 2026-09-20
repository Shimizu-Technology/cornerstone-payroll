# frozen_string_literal: true

module AirePayrollCalendar
  class Contract
    SCHEMA_VERSION = "1.1"
    TIME_ZONE = "Pacific/Guam"
    CUTOFF_DAYS_AFTER_PAY_DATE = CompanyPaySchedule::PAYROLL_CUTOFF_DAYS_BEFORE
    CUTOFF_POLICY = "after_regular_pay_date"

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
      # Legacy column name; the confirmed policy now counts days after the regular pay date.
      cutoff_days_after_pay_date = schedule.payroll_cutoff_days_before
      cutoff_date = pay_period.pay_date + cutoff_days_after_pay_date
      cutoff_hour, cutoff_minute = schedule.payroll_cutoff_at_minutes.divmod(60)
      cutoff_at = Time.find_zone!(TIME_ZONE).local(
        cutoff_date.year,
        cutoff_date.month,
        cutoff_date.day,
        cutoff_hour,
        cutoff_minute
      )
      {
        "schema_version" => SCHEMA_VERSION,
        "start_date" => pay_period.start_date.iso8601,
        "end_date" => pay_period.end_date.iso8601,
        "pay_date" => pay_period.pay_date.iso8601,
        "cutoff_at" => cutoff_at.iso8601,
        "time_zone" => TIME_ZONE,
        "cutoff_policy" => CUTOFF_POLICY,
        "cutoff_days_after_pay_date" => cutoff_days_after_pay_date
      }
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
      fail_contract!("AIRE payroll cutoff must remain seven calendar days after this regular pay date", "cutoff_rule_invalid") unless pay_schedule.payroll_cutoff_days_before == CUTOFF_DAYS_AFTER_PAY_DATE
      fail_contract!("Set the AIRE cutoff time to 5:00 p.m. Guam", "cutoff_time_invalid") unless pay_schedule.payroll_cutoff_at_minutes == 1_020
      fail_contract!("Confirm the legal overtime workweek before publishing this period", "workweek_confirmation_required") unless pay_period.resolved_company_workweek&.confirmed?
      fail_contract!("AIRE payroll periods must be the 1st–15th or 16th–month end", "period_dates_invalid") unless semimonthly_dates?
      fail_contract!("The pay date must be after the period end", "pay_date_invalid") unless pay_period.pay_date > pay_period.end_date

      true
    end

    private

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
