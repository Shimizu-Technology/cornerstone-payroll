# frozen_string_literal: true

module PayrollIntake
  class WorkweekEvidence
    PERIOD_DAYS = 14

    def initialize(pay_period:)
      @pay_period = pay_period
    end

    def capture!
      workweek = pay_period.resolved_company_workweek
      raise ArgumentError, "Confirm the employer's legal overtime workweek before previewing payroll intake" unless workweek&.confirmed?
      if workweek.starts_at_minutes.to_i != 0
        raise ArgumentError, "Spike payroll intake requires a legal workweek that starts at midnight"
      end
      unless (pay_period.end_date - pay_period.start_date).to_i == PERIOD_DAYS - 1
        raise ArgumentError, "Spike payroll intake requires a 14-day pay period containing two complete legal workweeks"
      end
      unless pay_period.start_date.wday == workweek.starts_on_weekday
        raise ArgumentError, "Spike payroll intake requires the pay period to begin on the confirmed legal workweek start day"
      end
      if workweek.effective_on > pay_period.start_date || (workweek.ends_on.present? && workweek.ends_on < pay_period.end_date)
        raise ArgumentError, "The confirmed legal workweek must cover the complete Spike pay period"
      end

      end_workweek = CompanyWorkweek.for_date(pay_period.company_id, pay_period.end_date)
      unless end_workweek&.id == workweek.id
        raise ArgumentError, "One confirmed legal workweek must cover the complete Spike pay period"
      end

      {
        "company_workweek_id" => workweek.id,
        "starts_on_weekday" => workweek.starts_on_weekday,
        "starts_at_minutes" => workweek.starts_at_minutes,
        "timezone" => workweek.timezone,
        "effective_on" => workweek.effective_on.iso8601,
        "updated_at" => workweek.updated_at.utc.iso8601(6),
        "pay_period_start" => pay_period.start_date.iso8601,
        "pay_period_end" => pay_period.end_date.iso8601,
        "legal_week_starts" => [ pay_period.start_date.iso8601, (pay_period.start_date + 7.days).iso8601 ]
      }
    end

    def validate_snapshot!(snapshot)
      expected = capture!
      actual = snapshot.to_h.stringify_keys
      return expected if actual == expected

      raise ArgumentError, "The legal workweek changed after this payroll intake preview. Create a new preview before applying."
    end

    private

    attr_reader :pay_period
  end
end
