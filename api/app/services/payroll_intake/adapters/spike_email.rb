# frozen_string_literal: true

module PayrollIntake
  module Adapters
    class SpikeEmail
      PARSER_VERSION = "spike_email:v1"
      SOURCE_TYPE = "spike_email"
      SOURCE_LABEL = "Spike Coffee Roasters email"
      HOURS_PER_WEEK_BEFORE_OT = 40.0

      def initialize(pay_period:, company:)
        @pay_period = pay_period
        @company = company
        @matcher = PayrollIntake::EmployeeMatcher.new(company: company)
      end

      def normalize(extracted_rows:, detected_period: nil)
        session_warnings = period_warnings(detected_period)
        rows = Array(extracted_rows).each_with_index.filter_map do |raw_row, index|
          normalize_row(raw_row.with_indifferent_access, index)
        end

        totals = {
          row_count: rows.length,
          ready_count: rows.count { |row| row[:status] == "ready" },
          review_count: rows.count { |row| row[:status] == "needs_review" },
          total_regular_hours: round(rows.sum { |row| row[:regular_hours].to_f }),
          total_overtime_hours: round(rows.sum { |row| row[:overtime_hours].to_f }),
          total_reported_tips: money(rows.sum { |row| row[:reported_tips].to_f }),
          total_tips_paid_out: money(rows.sum { |row| row[:tips_paid_out].to_f })
        }

        { rows: rows, warnings: session_warnings, totals: totals }
      end

      private

      attr_reader :pay_period, :company, :matcher

      def normalize_row(raw_row, index)
        name = raw_row[:employee_name].presence || raw_row[:name].presence || raw_row[:source_employee_name].presence
        return nil if name.blank?

        week1_hours = numeric(raw_row[:week1_hours] || raw_row[:week_1_hours] || raw_row[:first_week_hours])
        week2_hours = numeric(raw_row[:week2_hours] || raw_row[:week_2_hours] || raw_row[:second_week_hours])
        total_hours = numeric(raw_row[:total_hours])
        explicit_regular = value_present?(raw_row[:regular_hours])
        explicit_overtime = value_present?(raw_row[:overtime_hours])

        regular_hours, overtime_hours, hour_warnings = hours_for(
          week1_hours: week1_hours,
          week2_hours: week2_hours,
          total_hours: total_hours,
          regular_hours: numeric(raw_row[:regular_hours]),
          overtime_hours: numeric(raw_row[:overtime_hours]),
          explicit_regular: explicit_regular,
          explicit_overtime: explicit_overtime
        )

        week1_tips = money(raw_row[:week1_tips] || raw_row[:week_1_tips] || raw_row[:first_week_tips])
        week2_tips = money(raw_row[:week2_tips] || raw_row[:week_2_tips] || raw_row[:second_week_tips])
        extracted_total_tips = money(raw_row[:total_tips] || raw_row[:reported_tips] || raw_row[:tips_paid_out])
        summed_week_tips = money(week1_tips + week2_tips)
        total_tips = extracted_total_tips.positive? ? extracted_total_tips : summed_week_tips
        total_tips = summed_week_tips if extracted_total_tips.zero? && summed_week_tips.positive?

        warnings = []
        warnings.concat(hour_warnings)
        warnings << warning("missing_tips", "No paid-out tips were detected for this row. Confirm the source email before applying.", "warning") if total_tips.zero?
        if extracted_total_tips.positive? && summed_week_tips.positive? && (extracted_total_tips - summed_week_tips).abs > 0.01
          warnings << warning("tip_total_mismatch", "Week 1 + Week 2 tips do not tie to the extracted total tips.", "warning")
        end

        match = matcher.match(name)
        errors = []
        if match[:employee_id].blank?
          errors << error("unmatched_employee", "Select the Cornerstone employee for #{name} before applying.")
        elsif match[:confidence].to_f < 0.85
          warnings << warning("low_confidence_match", "Review the employee match before applying.", "warning")
        end

        status = errors.any? || warnings.any? ? "needs_review" : "ready"

        {
          position: index,
          source_employee_name: name.to_s.strip,
          employee_id: match[:employee_id],
          match_method: match[:method],
          match_confidence: match[:confidence],
          confidence: numeric(raw_row[:confidence]).positive? ? numeric(raw_row[:confidence]) : nil,
          week1_hours: round(week1_hours),
          week2_hours: round(week2_hours),
          regular_hours: round(regular_hours),
          overtime_hours: round(overtime_hours),
          week1_tips: week1_tips,
          week2_tips: week2_tips,
          reported_tips: total_tips,
          tips_paid_out: total_tips,
          loan_deduction: money(raw_row[:loan_deduction]),
          warnings: warnings,
          validation_errors: errors,
          status: status,
          source_payload: raw_row.to_h
        }
      end

      def hours_for(week1_hours:, week2_hours:, total_hours:, regular_hours:, overtime_hours:, explicit_regular:, explicit_overtime:)
        warnings = []

        if explicit_regular || explicit_overtime
          return [ regular_hours, overtime_hours, warnings ]
        end

        if week1_hours.positive? || week2_hours.positive?
          regular = [ week1_hours, HOURS_PER_WEEK_BEFORE_OT ].min + [ week2_hours, HOURS_PER_WEEK_BEFORE_OT ].min
          overtime = [ week1_hours - HOURS_PER_WEEK_BEFORE_OT, 0 ].max + [ week2_hours - HOURS_PER_WEEK_BEFORE_OT, 0 ].max
          return [ regular, overtime, warnings ]
        end

        if total_hours.positive?
          warnings << warning("biweekly_hours_without_week_split", "Only total hours were detected, so overtime cannot be verified. Split by week before applying if overtime is possible.", "warning")
          return [ total_hours, 0.0, warnings ]
        end

        [ 0.0, 0.0, warnings ]
      end

      def period_warnings(detected_period)
        return [] unless detected_period.is_a?(Hash)

        detected_start = parse_date(detected_period[:start_date] || detected_period["start_date"])
        detected_end = parse_date(detected_period[:end_date] || detected_period["end_date"])
        warnings = []

        if detected_start && detected_start != pay_period.start_date
          warnings << warning("period_start_mismatch", "Detected source start date #{detected_start.iso8601} does not match this pay period.", "warning")
        end
        if detected_end && detected_end != pay_period.end_date
          warnings << warning("period_end_mismatch", "Detected source end date #{detected_end.iso8601} does not match this pay period.", "warning")
        end

        warnings
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return nil if value.blank?

        Date.parse(value.to_s)
      rescue Date::Error
        nil
      end

      def numeric(value)
        return 0.0 if value.blank?

        BigDecimal(value.to_s.gsub(/[$,]/, "")).to_f
      rescue ArgumentError
        0.0
      end

      def money(value)
        BigDecimal(numeric(value).to_s).round(2).to_f
      end

      def round(value)
        BigDecimal(value.to_s).round(2).to_f
      rescue ArgumentError
        0.0
      end

      def value_present?(value)
        return false if value.nil?
        return false if value.respond_to?(:blank?) && value.blank?

        true
      end

      def warning(code, message, severity)
        { code: code, message: message, severity: severity }
      end

      def error(code, message)
        { code: code, message: message, severity: "error" }
      end
    end
  end
end
