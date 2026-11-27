# frozen_string_literal: true

module PayrollIntake
  class WorkweekEvidence
    PERIOD_DAYS = 14
    WEEKLY_PERIOD_DAYS = 7
    SEMIMONTHLY_DAYS_RANGE = (13..16).freeze
    MONTHLY_DAYS_RANGE = (28..31).freeze
    # Previews saved before these were recorded still apply if the rest matches.
    LATER_KEYS = %w[aligned_with_pay_period legal_week_starts].freeze

    # allow_misaligned: ONLY permissible when the source reports overtime itself
    # (overtime_mode == "source_reports", e.g., Revel). Computed overtime modes
    # (weekly_split, daily_records, total_as_regular_warn_over_80) must always
    # align with complete 7-day legal workweeks per 29 CFR 778.104.
    def initialize(pay_period:, allow_misaligned: false, overtime_mode: nil, workweek_alignment: nil)
      @pay_period = pay_period
      @overtime_mode = overtime_mode.presence&.to_s
      @workweek_alignment = workweek_alignment.presence&.to_s
      @allow_misaligned = if @overtime_mode.present?
        @overtime_mode == "source_reports"
      else
        allow_misaligned
      end
    end

    def capture!
      workweek = pay_period.resolved_company_workweek
      raise ArgumentError, "Confirm the employer's legal overtime workweek before previewing payroll intake" unless workweek&.confirmed?
      if workweek.starts_at_minutes.to_i != 0
        raise ArgumentError, "Payroll intake requires a legal workweek that starts at midnight"
      end

      validate_period_length!

      aligned = pay_period.start_date.wday == workweek.starts_on_weekday
      unless aligned || allow_misaligned
        raise ArgumentError, "Payroll intake requires the pay period to begin on the confirmed legal workweek start day"
      end
      if workweek.effective_on > pay_period.start_date || (workweek.ends_on.present? && workweek.ends_on < pay_period.end_date)
        raise ArgumentError, "The confirmed legal workweek must cover the complete pay period"
      end

      end_workweek = CompanyWorkweek.for_date(pay_period.company_id, pay_period.end_date)
      unless end_workweek&.id == workweek.id
        raise ArgumentError, "One confirmed legal workweek must cover the complete pay period"
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
        "aligned_with_pay_period" => aligned,
        "legal_week_starts" => (pay_period.start_date..pay_period.end_date)
          .select { |date| date.wday == workweek.starts_on_weekday }.map(&:iso8601)
      }
    end

    def validate_snapshot!(snapshot)
      expected = capture!
      actual = snapshot.to_h.stringify_keys
      return expected if actual == expected.except(*(LATER_KEYS - actual.keys))

      raise ArgumentError, "The legal workweek changed after this payroll intake preview. Create a new preview before applying."
    end

    private

    attr_reader :pay_period, :allow_misaligned, :overtime_mode, :workweek_alignment

    def pay_frequency
      pay_period.company&.pay_frequency.to_s.presence || "biweekly"
    end

    def source_reports_overtime?
      overtime_mode == "source_reports" || (overtime_mode.nil? && allow_misaligned)
    end

    def validate_period_length!
      span_days = (pay_period.end_date - pay_period.start_date).to_i + 1

      case pay_frequency
      when "weekly"
        return if span_days == WEEKLY_PERIOD_DAYS

        raise ArgumentError, "Payroll intake requires a 7-day pay period containing one complete legal workweek"
      when "semimonthly"
        unless source_reports_overtime?
          raise ArgumentError,
                "Payroll calculates overtime only from complete 7-day workweeks (weekly or biweekly pay periods per 29 CFR 778.104). " \
                "Use source-reported overtime for semimonthly pay periods."
        end
        return if SEMIMONTHLY_DAYS_RANGE.cover?(span_days)

        raise ArgumentError, "Payroll intake requires a valid semimonthly pay period (#{SEMIMONTHLY_DAYS_RANGE.min}–#{SEMIMONTHLY_DAYS_RANGE.max} days)"
      when "monthly"
        unless source_reports_overtime?
          raise ArgumentError,
                "Payroll calculates overtime only from complete 7-day workweeks (weekly or biweekly pay periods per 29 CFR 778.104). " \
                "Use source-reported overtime for monthly pay periods."
        end
        return if MONTHLY_DAYS_RANGE.cover?(span_days)

        raise ArgumentError, "Payroll intake requires a valid monthly pay period (#{MONTHLY_DAYS_RANGE.min}–#{MONTHLY_DAYS_RANGE.max} days)"
      else
        return if span_days == PERIOD_DAYS

        raise ArgumentError, "Payroll intake requires a 14-day pay period containing two complete legal workweeks"
      end
    end
  end
end
