# frozen_string_literal: true

require "bigdecimal"

module PayrollIntake
  # Shared overtime-mode, workweek, and calculation policy for portal
  # `extra_hours` client changes across:
  # - Client portal period detail (`PayrollSubmissions::Serializer`)
  # - Client portal submission validation (`PayrollSubmissions::ChangeRows`)
  # - Staff review prefill & apply (`PayrollSubmissions::ImportChanges`)
  # - Shared payroll item application (`PayrollIntake::ClientChangeApplier`)
  #
  # All hours and money calculations use BigDecimal.
  class ExtraHoursPolicy
    MAX_EXTRA_HOURS = BigDecimal("1000")
    MAX_WEEK_HOURS = PayrollIntake::Adapters::CornerstoneWorkbook::MAX_HOURS_PER_WEEK
    OVERTIME_MULTIPLIER = BigDecimal("1.5")
    RECONCILIATION_TOLERANCE = BigDecimal("0.01")
    DECIMAL_PATTERN = /\A\d{1,9}(\.\d{1,2})?\z/

    class << self
      def overtime_mode_for(company:, pay_period: nil, source_type: nil, session: nil, on: nil)
        if session
          snapshot = session.evidence_snapshot.to_h
          return snapshot.dig("intake_settings", "overtime_mode").to_s if snapshot.dig("intake_settings", "overtime_mode").present?
          return snapshot["overtime_mode"].to_s if snapshot["overtime_mode"].present?

          return PayrollIntake::EffectiveSettings.for(
            company: company,
            pay_period: pay_period,
            source_type: session.source_type,
            on: on
          ).overtime_mode
        end

        resolved_source = source_type.presence || company&.portal_submittable_intake_descriptor&.key || "mosa_revel"
        PayrollIntake::EffectiveSettings.for(
          company: company,
          pay_period: pay_period,
          source_type: resolved_source,
          on: on
        ).overtime_mode
      end

      def workweeks_for(company:, start_date:, end_date:, pay_period: nil, overtime_mode: nil)
        return [] if overtime_mode.to_s == "source_reports"
        return [] unless start_date && end_date

        period_start = start_date.to_date
        period_end = end_date.to_date
        span_days = (period_end - period_start).to_i + 1
        frequency = PayrollIntake::WorkweekEvidence.pay_frequency_for(
          pay_period: pay_period,
          company: company,
          start_date: period_start
        )

        if frequency == "weekly" || (!frequency.in?(%w[semimonthly monthly]) && span_days == 7)
          return [] unless span_days == 7

          [ build_workweek(1, period_start, period_end) ]
        elsif frequency == "biweekly" || (!frequency.in?(%w[semimonthly monthly]) && span_days == 14)
          return [] unless span_days == 14

          [
            build_workweek(1, period_start, period_start + 6),
            build_workweek(2, period_start + 7, period_end)
          ]
        else
          []
        end
      end

      def period_config(company:, start_date:, end_date:, pay_period: nil, source_type: nil, session: nil)
        overtime_mode = overtime_mode_for(
          company: company,
          pay_period: pay_period,
          source_type: source_type,
          session: session,
          on: end_date
        )
        workweeks = workweeks_for(
          company: company,
          start_date: start_date,
          end_date: end_date,
          pay_period: pay_period,
          overtime_mode: overtime_mode
        )
        {
          mode: workweeks.any? ? "workweek" : "split",
          overtime_mode: overtime_mode,
          workweeks: workweeks
        }
      end

      def contractor?(employee, as_of:)
        return false unless employee

        employee.payroll_compensation_on(as_of).employment_type == "contractor"
      end

      # Resolves the effective extra-hours mode, baseline hours, and projected
      # result for a single employee's extra-hours change during staff review.
      def proposal_context(employee:, pay_period:, period_config:, source_row:, existing_item:, change_row:, rate:)
        is_contractor = contractor?(employee, as_of: pay_period.end_date)
        baseline = resolve_baseline(
          period_config: period_config,
          source_row: source_row,
          existing_item: existing_item
        )

        mode = if is_contractor
          "straight_time"
        elsif period_config[:mode] == "workweek" && baseline[:has_week_breakdown]
          "workweek"
        else
          "split"
        end

        fallback_reason = if !is_contractor && period_config[:mode] == "workweek" && !baseline[:has_week_breakdown]
          "This employee's existing hours have no weekly breakdown, so enter regular and overtime hours directly."
        end

        workweeks = mode == "workweek" ? period_config[:workweeks] : []
        submitted_workweek = integer_or_nil(change_row["workweek"])
        effective_workweek = if mode == "workweek"
          if workweeks.size == 1
            1
          elsif submitted_workweek && submitted_workweek.between?(1, workweeks.size)
            submitted_workweek
          end
        end

        has_submitted_split = change_row.key?("regular_hours") || change_row.key?("overtime_hours")
        submitted_regular = has_submitted_split ? format_hours(decimal_or_zero(change_row["regular_hours"])) : nil
        submitted_overtime = has_submitted_split ? format_hours(decimal_or_zero(change_row["overtime_hours"])) : nil

        needs_classification = case mode
        when "straight_time"
          false
        when "workweek"
          workweeks.size > 1 && effective_workweek.nil?
        else
          !has_submitted_split
        end

        projection = if !needs_classification && rate&.rate
          compute_projection(
            mode: mode,
            baseline: baseline,
            workweeks: workweeks,
            rate: rate.rate.to_d,
            hours: change_row["hours"],
            regular_hours: submitted_regular,
            overtime_hours: submitted_overtime,
            workweek: effective_workweek
          )
        end

        {
          extra_hours_mode: mode,
          is_contractor: is_contractor,
          workweeks: workweeks,
          workweek: effective_workweek,
          workweek_start_date: effective_workweek ? workweeks.find { |w| w[:index] == effective_workweek }&.dig(:start_date) : nil,
          workweek_end_date: effective_workweek ? workweeks.find { |w| w[:index] == effective_workweek }&.dig(:end_date) : nil,
          regular_hours: mode == "split" ? submitted_regular : nil,
          overtime_hours: mode == "split" ? submitted_overtime : nil,
          needs_classification: needs_classification,
          fallback_reason: fallback_reason,
          baseline_regular_hours: baseline[:regular_hours].to_s("F"),
          baseline_overtime_hours: baseline[:overtime_hours].to_s("F"),
          baseline_week1_hours: mode == "workweek" ? baseline[:week1_hours].to_s("F") : nil,
          baseline_week2_hours: mode == "workweek" ? baseline[:week2_hours].to_s("F") : nil,
          delta_regular_hours: projection&.dig(:delta_regular_hours)&.to_s("F"),
          delta_overtime_hours: projection&.dig(:delta_overtime_hours)&.to_s("F"),
          resulting_regular_hours: projection&.dig(:resulting_regular_hours)&.to_s("F"),
          resulting_overtime_hours: projection&.dig(:resulting_overtime_hours)&.to_s("F"),
          gross_pay_delta: projection ? format("%.2f", projection[:gross_pay_delta]) : nil
        }.compact
      end

      # Computes exact BigDecimal deltas and resulting totals. Raises ArgumentError
      # when inputs are invalid or exceed weekly/total caps.
      def resolve_deltas!(mode:, baseline_regular:, baseline_overtime:, rate:,
                          hours: nil, regular_hours: nil, overtime_hours: nil,
                          workweek: nil, workweeks: [], baseline_week1: 0.to_d, baseline_week2: 0.to_d)
        base_reg = BigDecimal(baseline_regular.to_s.presence || "0").round(2)
        base_ot = BigDecimal(baseline_overtime.to_s.presence || "0").round(2)
        hourly_rate = BigDecimal(rate.to_s)

        case mode.to_s
        when "straight_time"
          ot_check = decimal_or_zero(overtime_hours)
          raise ArgumentError, "1099 contractors do not receive overtime hours." if ot_check.positive?

          total = parse_positive_hours!(hours.presence || regular_hours, label: "hours")
          {
            hours_mode: "straight_time",
            hours: total,
            delta_regular_hours: total,
            delta_overtime_hours: 0.to_d,
            resulting_regular_hours: (base_reg + total).round(2),
            resulting_overtime_hours: base_ot,
            gross_pay_delta: (total * hourly_rate).round(2)
          }
        when "split"
          reg = parse_nonnegative_hours!(regular_hours.presence || "0", label: "regular hours")
          ot = parse_nonnegative_hours!(overtime_hours.presence || "0", label: "overtime hours")
          total = (reg + ot).round(2)
          unless total.positive? && total <= MAX_EXTRA_HOURS
            raise ArgumentError, "Enter regular hours and/or overtime hours greater than zero (up to #{MAX_EXTRA_HOURS.to_i} total)."
          end

          gross_delta = ((reg * hourly_rate).round(2) + (ot * hourly_rate * OVERTIME_MULTIPLIER).round(2)).round(2)
          {
            hours_mode: "split",
            hours: total,
            delta_regular_hours: reg,
            delta_overtime_hours: ot,
            resulting_regular_hours: (base_reg + reg).round(2),
            resulting_overtime_hours: (base_ot + ot).round(2),
            gross_pay_delta: gross_delta
          }
        when "workweek"
          total = parse_positive_hours!(hours, label: "hours")
          week_index = integer_or_nil(workweek)
          max_week = workweeks.any? ? workweeks.size : 2
          unless week_index && week_index.between?(1, max_week)
            raise ArgumentError, "Choose which workweek the extra hours belong to."
          end

          base_w1 = BigDecimal(baseline_week1.to_s.presence || "0").round(2)
          base_w2 = BigDecimal(baseline_week2.to_s.presence || "0").round(2)
          expected_reg, expected_ot = PayrollIntake::Adapters::CornerstoneWorkbook.split_for_weekly_hours(base_w1, base_w2)
          unless reconciles?(expected_reg, base_reg) && reconciles?(expected_ot, base_ot)
            raise ArgumentError, "Weekly hours baseline no longer matches saved hours. Reopen the review before applying."
          end

          new_w1 = week_index == 1 ? (base_w1 + total).round(2) : base_w1
          new_w2 = week_index == 2 ? (base_w2 + total).round(2) : base_w2
          if new_w1 > MAX_WEEK_HOURS || new_w2 > MAX_WEEK_HOURS
            raise ArgumentError, "Workweek #{week_index} total hours cannot exceed #{MAX_WEEK_HOURS.to_i} hours."
          end

          new_reg, new_ot = PayrollIntake::Adapters::CornerstoneWorkbook.split_for_weekly_hours(new_w1, new_w2)
          delta_reg = (new_reg - base_reg).round(2)
          delta_ot = (new_ot - base_ot).round(2)
          gross_delta = ((delta_reg * hourly_rate).round(2) + (delta_ot * hourly_rate * OVERTIME_MULTIPLIER).round(2)).round(2)
          week_meta = workweeks.find { |candidate| candidate[:index] == week_index }

          {
            hours_mode: "workweek",
            hours: total,
            workweek: week_index,
            workweek_start_date: week_meta&.dig(:start_date),
            workweek_end_date: week_meta&.dig(:end_date),
            new_week1_hours: new_w1,
            new_week2_hours: new_w2,
            delta_regular_hours: delta_reg,
            delta_overtime_hours: delta_ot,
            resulting_regular_hours: new_reg,
            resulting_overtime_hours: new_ot,
            gross_pay_delta: gross_delta
          }
        else
          raise ArgumentError, "Choose regular/overtime hours or a workweek before applying extra hours."
        end
      end

      def format_hours(value)
        BigDecimal(value.to_s).round(2).to_s("F").delete_suffix(".0")
      end

      def valid_nonnegative_decimal?(value)
        text = value.to_s.strip
        return false unless text.match?(DECIMAL_PATTERN)

        number = BigDecimal(text)
        number >= 0 && number <= MAX_EXTRA_HOURS
      end

      def parse_nonnegative_hours!(value, label:)
        text = value.to_s.strip
        unless text.match?(DECIMAL_PATTERN)
          raise ArgumentError, "Enter a valid #{label} value."
        end

        number = BigDecimal(text).round(2)
        if number.negative? || number > MAX_EXTRA_HOURS
          raise ArgumentError, "Enter #{label} between 0 and #{MAX_EXTRA_HOURS.to_i}."
        end

        number
      end

      def parse_positive_hours!(value, label:)
        number = parse_nonnegative_hours!(value, label: label)
        raise ArgumentError, "Enter #{label} greater than zero." unless number.positive?

        number
      end

      private

      def resolve_baseline(period_config:, source_row:, existing_item:)
        source = source_row&.to_h&.deep_symbolize_keys
        if source.present? && !source[:workbook_only]
          base_reg = decimal_or_zero(source[:regular_hours])
          base_ot = decimal_or_zero(source[:overtime_hours])
          has_week_keys = source.key?(:week1_hours) || source.key?(:week2_hours)
          w1 = decimal_or_zero(source[:week1_hours])
          w2 = decimal_or_zero(source[:week2_hours])
          has_breakdown = false
          if period_config[:mode] == "workweek" && has_week_keys
            split_reg, split_ot = PayrollIntake::Adapters::CornerstoneWorkbook.split_for_weekly_hours(w1, w2)
            weekly_ok = period_config[:workweeks].size > 1 || w2.zero?
            has_breakdown = weekly_ok && reconciles?(split_reg, base_reg) && reconciles?(split_ot, base_ot)
          end

          return {
            regular_hours: base_reg,
            overtime_hours: base_ot,
            week1_hours: has_breakdown ? w1 : 0.to_d,
            week2_hours: has_breakdown ? w2 : 0.to_d,
            has_week_breakdown: has_breakdown
          }
        end

        previous = existing_item&.custom_columns_data.to_h["client_change_evidence"].to_h
        base_reg = if previous["kind"] == "extra_hours" && previous.key?("baseline_regular_hours")
          decimal_or_zero(previous["baseline_regular_hours"])
        else
          decimal_or_zero(existing_item&.hours_worked)
        end
        base_ot = if previous["kind"] == "extra_hours" && previous.key?("baseline_overtime_hours")
          decimal_or_zero(previous["baseline_overtime_hours"])
        else
          decimal_or_zero(existing_item&.overtime_hours)
        end

        # A zero-hour baseline has a known 0/0 weekly breakdown. Existing non-zero
        # worksheet hours without a weekly source have no breakdown to recompute from.
        has_breakdown = period_config[:mode] == "workweek" && base_reg.zero? && base_ot.zero?
        {
          regular_hours: base_reg,
          overtime_hours: base_ot,
          week1_hours: 0.to_d,
          week2_hours: 0.to_d,
          has_week_breakdown: has_breakdown
        }
      end

      def compute_projection(mode:, baseline:, workweeks:, rate:, hours:, regular_hours:, overtime_hours:, workweek:)
        resolve_deltas!(
          mode: mode,
          baseline_regular: baseline[:regular_hours],
          baseline_overtime: baseline[:overtime_hours],
          rate: rate,
          hours: hours,
          regular_hours: regular_hours,
          overtime_hours: overtime_hours,
          workweek: workweek,
          workweeks: workweeks,
          baseline_week1: baseline[:week1_hours],
          baseline_week2: baseline[:week2_hours]
        )
      rescue ArgumentError
        nil
      end

      def build_workweek(index, start_date, end_date)
        {
          index: index,
          start_date: start_date.iso8601,
          end_date: end_date.iso8601,
          label: short_range_label(start_date, end_date)
        }
      end

      def short_range_label(start_date, end_date)
        if start_date.year != end_date.year
          "#{start_date.strftime('%b %-d, %Y')} – #{end_date.strftime('%b %-d, %Y')}"
        elsif start_date.month != end_date.month
          "#{start_date.strftime('%b %-d')} – #{end_date.strftime('%b %-d')}"
        else
          "#{start_date.strftime('%b %-d')}–#{end_date.strftime('%-d')}"
        end
      end

      def reconciles?(left, right)
        (BigDecimal(left.to_s) - BigDecimal(right.to_s)).abs <= RECONCILIATION_TOLERANCE
      end

      def decimal_or_zero(value)
        BigDecimal(value.to_s, exception: false)&.round(2) || 0.to_d
      end

      def integer_or_nil(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Integer(value.to_s, 10)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
