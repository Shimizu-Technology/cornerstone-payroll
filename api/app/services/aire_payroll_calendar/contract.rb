# frozen_string_literal: true

module AirePayrollCalendar
  class Contract
    SCHEMA_VERSION = "1.0"
    TIME_ZONE = "Pacific/Guam"
    CUTOFF_DAYS_BEFORE = CompanyPaySchedule::PAYROLL_CUTOFF_DAYS_BEFORE

    class Error < StandardError; end

    attr_reader :pay_period

    def initialize(pay_period)
      @pay_period = pay_period
    end

    def payload
      validate!
      schedule = pay_schedule
      cutoff_date = pay_period.pay_date - schedule.payroll_cutoff_days_before
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
        "cutoff_days_before" => schedule.payroll_cutoff_days_before
      }
    end

    def validate!
      raise Error, "Only regular payroll runs can be published to AIRE" unless pay_period.regular_cycle? && pay_period.regular_run?
      raise Error, "AIRE payroll periods require a confirmed semimonthly pay schedule" unless confirmed_semimonthly_schedule?
      raise Error, "AIRE payroll cutoff must remain seven calendar days before pay date" unless pay_schedule.payroll_cutoff_days_before == CUTOFF_DAYS_BEFORE
      raise Error, "Confirm the legal overtime workweek before publishing this period" unless pay_period.resolved_company_workweek&.confirmed?
      raise Error, "AIRE payroll periods must be the 1st–15th or 16th–month end" unless semimonthly_dates?
      raise Error, "The pay date must be after the period end" unless pay_period.pay_date > pay_period.end_date

      true
    end

    private

    def confirmed_semimonthly_schedule?
      schedule = pay_schedule
      schedule&.confirmed? && schedule.frequency == "semimonthly" && schedule.period_rule == "semimonthly" && schedule.timezone == TIME_ZONE
    end

    def pay_schedule
      @pay_schedule ||= pay_period.company_pay_schedule || CompanyPaySchedule.for_date(pay_period.company_id, pay_period.start_date)
    end

    def semimonthly_dates?
      first_half = pay_period.start_date.day == 1 && pay_period.end_date == Date.new(pay_period.start_date.year, pay_period.start_date.month, 15)
      second_half = pay_period.start_date.day == 16 && pay_period.end_date == pay_period.start_date.end_of_month
      first_half || second_half
    end
  end
end
