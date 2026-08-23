# frozen_string_literal: true

module PayrollIntake
  module Adapters
    class SpikeEmail
      PARSER_VERSION = "spike_email:v3"
      SOURCE_TYPE = "spike_email"
      SOURCE_LABEL = "Spike Coffee Roasters email"
      HOURS_PER_WEEK_BEFORE_OT = 40.0
      RECONCILIATION_TOLERANCE = 0.01

      def self.split_for_weekly_hours(week1_hours, week2_hours)
        weeks = [ week1_hours, week2_hours ].map { |value| BigDecimal(value.to_s.presence || "0") }
        regular = weeks.sum { |hours| [ hours, BigDecimal(HOURS_PER_WEEK_BEFORE_OT.to_s) ].min }
        overtime = weeks.sum { |hours| [ hours - BigDecimal(HOURS_PER_WEEK_BEFORE_OT.to_s), 0.to_d ].max }
        [ regular.round(2).to_f, overtime.round(2).to_f ]
      rescue ArgumentError
        [ 0.0, 0.0 ]
      end

      def self.text_parser_class
        PayrollIntake::SpikeEmailTextParser
      end

      def self.ai_extraction_instructions
        <<~PROMPT
          Source-specific instructions for Spike Coffee Roasters:
          - Credit card/cash tips are paid out daily. Extract source tips exactly as shown; the adapter will map them to reported_tips and tips_paid_out during normalization.
          - If the screenshot has two weekly sections, keep week 1 and week 2 separate.
          - If only a biweekly total is visible, use total_hours and explain the uncertainty in warnings.
          - Do not infer overtime from a biweekly total unless weekly hours or explicit overtime are visible.
        PROMPT
      end

      def self.ai_extraction_schema
        <<~PROMPT
          Required JSON shape:
          {
            "detected_period": { "start_date": "YYYY-MM-DD" or null, "end_date": "YYYY-MM-DD" or null },
            "rows": [
              {
                "employee_name": string,
                "week1_hours": number or null,
                "week2_hours": number or null,
                "regular_hours": number or null,
                "overtime_hours": number or null,
                "total_hours": number or null,
                "week1_tips": number or null,
                "week2_tips": number or null,
                "total_tips": number or null,
                "loan_deduction": number or null,
                "confidence": number between 0 and 1
              }
            ],
            "warnings": [string]
          }
        PROMPT
      end

      def initialize(pay_period:, company:)
        @pay_period = pay_period
        @company = company
        @matcher = PayrollIntake::EmployeeMatcher.new(company: company)
      end

      def normalize(extracted_rows:, detected_period: nil)
        source_period = validate_period!(detected_period)
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

        { rows: rows, warnings: [], totals: totals, evidence: { "source_period" => source_period } }
      end

      private

      attr_reader :pay_period, :company, :matcher

      def normalize_row(raw_row, index)
        name = raw_row[:employee_name].presence || raw_row[:name].presence || raw_row[:source_employee_name].presence
        return nil if name.blank?

        week1_value = raw_row[:week1_hours] || raw_row[:week_1_hours] || raw_row[:first_week_hours]
        week2_value = raw_row[:week2_hours] || raw_row[:week_2_hours] || raw_row[:second_week_hours]
        week1_hours = numeric(week1_value)
        week2_hours = numeric(week2_value)
        total_hours = numeric(raw_row[:total_hours])
        week1_present = value_present?(week1_value)
        week2_present = value_present?(week2_value)
        total_present = value_present?(raw_row[:total_hours])
        explicit_regular = value_present?(raw_row[:regular_hours])
        explicit_overtime = value_present?(raw_row[:overtime_hours])

        regular_hours, overtime_hours, hour_errors = hours_for(
          week1_hours: week1_hours,
          week2_hours: week2_hours,
          total_hours: total_hours,
          regular_hours: numeric(raw_row[:regular_hours]),
          overtime_hours: numeric(raw_row[:overtime_hours]),
          week1_present: week1_present,
          week2_present: week2_present,
          total_present: total_present,
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
        warnings << warning("missing_tips", "No paid-out tips were detected for this row. Confirm the source email before applying.", "warning") if total_tips.zero?
        if extracted_total_tips.positive? && summed_week_tips.positive? && (extracted_total_tips - summed_week_tips).abs > 0.01
          warnings << warning("tip_total_mismatch", "Week 1 + Week 2 tips do not tie to the extracted total tips.", "warning")
        end

        match = matcher.match(name)
        errors = hour_errors
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

      def hours_for(week1_hours:, week2_hours:, total_hours:, regular_hours:, overtime_hours:, week1_present:, week2_present:, total_present:, explicit_regular:, explicit_overtime:)
        errors = []
        if week1_present != week2_present
          errors << error("incomplete_weekly_hours", "Both Week 1 and Week 2 hours are required before overtime can be calculated.")
        end

        if week1_present && week2_present
          if week1_hours > 168 || week2_hours > 168
            errors << error("weekly_hours_out_of_range", "A legal workweek cannot contain more than 168 hours.")
          end

          regular, overtime = self.class.split_for_weekly_hours(week1_hours, week2_hours)
          weekly_total = round(week1_hours + week2_hours)
          if total_present && !reconciles?(weekly_total, total_hours)
            errors << error("weekly_total_mismatch", "Week 1 + Week 2 hours do not tie to the extracted total hours.")
          end
          if explicit_regular != explicit_overtime
            errors << error("incomplete_overtime_split", "Extracted regular and overtime hours must be supplied together.")
          elsif explicit_regular && (!reconciles?(regular, regular_hours) || !reconciles?(overtime, overtime_hours))
            errors << error("overtime_split_mismatch", "Extracted regular/overtime hours do not match the legal weekly calculation.")
          end

          return [ regular, overtime, errors ]
        end

        supplied_total = if total_present
          total_hours
        elsif explicit_regular || explicit_overtime
          regular_hours + overtime_hours
        else
          0.0
        end
        if supplied_total.positive?
          errors << error("weekly_hours_required", "Enter Week 1 and Week 2 hours so Payroll can calculate overtime from the confirmed legal workweek.")
        end
        if explicit_regular != explicit_overtime
          errors << error("incomplete_overtime_split", "Extracted regular and overtime hours must be supplied together.")
        elsif total_present && explicit_regular && !reconciles?(regular_hours + overtime_hours, total_hours)
          errors << error("source_total_mismatch", "Extracted regular + overtime hours do not tie to the extracted total hours.")
        end

        [ total_present ? total_hours : regular_hours, explicit_overtime ? overtime_hours : 0.0, errors ]
      end

      def validate_period!(detected_period)
        unless detected_period.is_a?(Hash)
          raise ArgumentError, "The Spike source must show the complete pay-period start and end dates"
        end
        detected_start = parse_date(detected_period[:start_date] || detected_period["start_date"])
        detected_end = parse_date(detected_period[:end_date] || detected_period["end_date"])
        unless detected_start && detected_end
          raise ArgumentError, "The Spike source must show valid pay-period start and end dates"
        end
        unless detected_start == pay_period.start_date && detected_end == pay_period.end_date
          raise ArgumentError,
                "The detected Spike source period #{detected_start.iso8601}–#{detected_end.iso8601} does not match this pay period"
        end

        { "start_date" => detected_start.iso8601, "end_date" => detected_end.iso8601 }
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return nil if value.blank?

        cleaned = value.to_s.strip
        year_token = cleaned.split(/[\/-]/).last.to_s
        format = year_token.length == 2 ? "%m/%d/%y" : "%m/%d/%Y"

        Date.strptime(cleaned, format)
      rescue Date::Error
        Date.parse(cleaned)
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

      def reconciles?(left, right)
        (BigDecimal(left.to_s) - BigDecimal(right.to_s)).abs <= BigDecimal(RECONCILIATION_TOLERANCE.to_s)
      rescue ArgumentError
        false
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
