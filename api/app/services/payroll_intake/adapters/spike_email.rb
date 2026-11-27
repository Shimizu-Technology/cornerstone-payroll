# frozen_string_literal: true

module PayrollIntake
  module Adapters
    class SpikeEmail
      PARSER_VERSION = "spike_email:v3"
      SOURCE_TYPE = "spike_email"
      SOURCE_LABEL = "Spike Coffee Roasters email"
      HOURS_PER_WEEK_BEFORE_OT = 40.0
      RECONCILIATION_TOLERANCE = 0.01

      DESCRIPTOR = PayrollIntake::Descriptor.new(
        key: SOURCE_TYPE,
        label: SOURCE_LABEL,
        source_label: SOURCE_LABEL,
        parser_version: PARSER_VERSION,
        adapter_class: self,
        extraction: "text_and_ai",
        accepts_pasted_text: true,
        tracks_reviewed_hours: false,
        employee_match: "name_fuzzy",
        idempotency: "files_and_workweek",
        reports_overtime: false,
        tips_default: "already_paid_out",
        overtime_mode: "weekly_split",
        workweek_alignment: "aligned",
        files: [],
        portal: { submittable: false, role_map: {} }
      )

      def self.descriptor
        DESCRIPTOR
      end

      def self.source_roles
        descriptor.source_roles
      end

      def self.default_required_source_roles
        descriptor.default_required_source_roles
      end

      def self.reports_overtime?
        descriptor.reports_overtime?
      end

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
        @effective_settings = PayrollIntake::EffectiveSettings.for(
          company: company,
          pay_period: pay_period,
          source_type: SOURCE_TYPE
        )
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
          total_regular_hours: round(rows.sum(0.to_d) { |row| BigDecimal(row[:regular_hours].to_s) }),
          total_overtime_hours: round(rows.sum(0.to_d) { |row| BigDecimal(row[:overtime_hours].to_s) }),
          total_reported_tips: money(rows.sum(0.to_d) { |row| BigDecimal(row[:reported_tips].to_s) }),
          total_tips_paid_out: money(rows.sum(0.to_d) { |row| BigDecimal(row[:tips_paid_out].to_s) })
        }

        evidence = {
          "source_period" => source_period,
          "overtime_mode" => effective_settings.overtime_mode,
          "tip_treatment" => {
            "default" => effective_settings.tips_default,
            "source" => effective_settings.source
          }
        }

        { rows: rows, warnings: [], totals: totals, evidence: evidence }
      end

      private

      attr_reader :pay_period, :company, :matcher, :effective_settings

      def normalize_row(raw_row, index)
        name = raw_row[:employee_name].presence || raw_row[:name].presence || raw_row[:source_employee_name].presence
        return nil if name.blank?

        week1_value = raw_row[:week1_hours] || raw_row[:week_1_hours] || raw_row[:first_week_hours]
        week2_value = raw_row[:week2_hours] || raw_row[:week_2_hours] || raw_row[:second_week_hours]
        week1_hours = decimal(week1_value)
        week2_hours = decimal(week2_value)
        total_hours = decimal(raw_row[:total_hours])
        week1_present = value_present?(week1_value)
        week2_present = value_present?(week2_value)
        total_present = value_present?(raw_row[:total_hours])
        explicit_regular = value_present?(raw_row[:regular_hours])
        explicit_overtime = value_present?(raw_row[:overtime_hours])

        regular_hours, overtime_hours, hour_errors, hour_warnings = hours_for(
          week1_hours: week1_hours,
          week2_hours: week2_hours,
          total_hours: total_hours,
          regular_hours: decimal(raw_row[:regular_hours]),
          overtime_hours: decimal(raw_row[:overtime_hours]),
          week1_present: week1_present,
          week2_present: week2_present,
          total_present: total_present,
          explicit_regular: explicit_regular,
          explicit_overtime: explicit_overtime,
          daily_hours: raw_row[:daily_hours] || raw_row[:days]
        )

        week1_tips = money_decimal(raw_row[:week1_tips] || raw_row[:week_1_tips] || raw_row[:first_week_tips])
        week2_tips = money_decimal(raw_row[:week2_tips] || raw_row[:week_2_tips] || raw_row[:second_week_tips])
        extracted_total_tips = money_decimal(raw_row[:total_tips] || raw_row[:reported_tips] || raw_row[:tips_paid_out])
        summed_week_tips = (week1_tips + week2_tips).round(2)
        total_tips = extracted_total_tips.positive? ? extracted_total_tips : summed_week_tips
        total_tips = summed_week_tips if extracted_total_tips.zero? && summed_week_tips.positive?

        row_tip_override = parse_optional_boolean(raw_row[:tips_already_paid])
        tips_already_paid = row_tip_override.nil? ? effective_settings.tips_already_paid_default? : row_tip_override
        tip_treatment_source = row_tip_override.nil? ? effective_settings.source : "row_override"
        tips_paid_out = tips_already_paid ? total_tips : 0.to_d

        warnings = Array(hour_warnings)
        if total_tips.zero? && tips_already_paid
          warnings << warning("missing_tips", "No paid-out tips were detected for this row. Confirm the source email before applying.", "warning")
        end
        if extracted_total_tips.positive? && summed_week_tips.positive? && (extracted_total_tips - summed_week_tips).abs > BigDecimal("0.01")
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
          week1_tips: week1_tips.to_f,
          week2_tips: week2_tips.to_f,
          reported_tips: total_tips.to_f,
          tips_paid_out: tips_paid_out.to_f,
          loan_deduction: money(raw_row[:loan_deduction]),
          warnings: warnings,
          validation_errors: errors,
          status: status,
          source_payload: raw_row.to_h.merge(
            "resolved_tip_treatment" => (tips_already_paid ? "already_paid_out" : "paid_in_check"),
            "tip_treatment_source" => tip_treatment_source,
            "resolved_overtime_mode" => effective_settings.overtime_mode
          )
        }
      end

      def hours_for(week1_hours:, week2_hours:, total_hours:, regular_hours:, overtime_hours:, week1_present:, week2_present:, total_present:, explicit_regular:, explicit_overtime:, daily_hours: nil)
        case effective_settings.overtime_mode
        when "source_reports"
          hours_for_source_reports(
            total_hours: total_hours,
            regular_hours: regular_hours,
            overtime_hours: overtime_hours,
            total_present: total_present,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime
          )
        when "total_as_regular_warn_over_80"
          hours_for_total_as_regular_warn_over_threshold(
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            total_hours: total_hours,
            regular_hours: regular_hours,
            overtime_hours: overtime_hours,
            week1_present: week1_present,
            week2_present: week2_present,
            total_present: total_present,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime
          )
        when "daily_records"
          hours_for_daily_records(
            daily_hours: daily_hours,
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            total_hours: total_hours,
            regular_hours: regular_hours,
            overtime_hours: overtime_hours,
            week1_present: week1_present,
            week2_present: week2_present,
            total_present: total_present,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime
          )
        else
          hours_for_weekly_split(
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            total_hours: total_hours,
            regular_hours: regular_hours,
            overtime_hours: overtime_hours,
            week1_present: week1_present,
            week2_present: week2_present,
            total_present: total_present,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime
          )
        end
      end

      def weekly_frequency?
        company.pay_frequency.to_s == "weekly"
      end

      def period_regular_hours_threshold
        weekly_frequency? ? BigDecimal("40") : BigDecimal("80")
      end

      def hours_for_weekly_split(week1_hours:, week2_hours:, total_hours:, regular_hours:, overtime_hours:, week1_present:, week2_present:, total_present:, explicit_regular:, explicit_overtime:)
        errors = []
        if weekly_frequency?
          if week1_present
            if week1_hours > 168
              errors << error("weekly_hours_out_of_range", "A legal workweek cannot contain more than 168 hours.")
            end
            regular, overtime = self.class.split_for_weekly_hours(week1_hours, 0)
            if total_present && !reconciles?(week1_hours, total_hours)
              errors << error("weekly_total_mismatch", "Week 1 hours do not tie to the extracted total hours.")
            end
            if explicit_regular != explicit_overtime
              errors << error("incomplete_overtime_split", "Extracted regular and overtime hours must be supplied together.")
            elsif explicit_regular && (!reconciles?(regular, regular_hours) || !reconciles?(overtime, overtime_hours))
              errors << error("overtime_split_mismatch", "Extracted regular/overtime hours do not match the legal weekly calculation.")
            end
            return [ regular, overtime, errors, [] ]
          end

          supplied_total = total_present ? total_hours : (explicit_regular || explicit_overtime ? regular_hours + overtime_hours : 0.to_d)
          if supplied_total.positive?
            errors << error("weekly_hours_required", "Enter Week 1 hours so Payroll can calculate overtime from the confirmed legal workweek.")
          end
          return [ total_present ? total_hours : regular_hours, explicit_overtime ? overtime_hours : 0.to_d, errors, [] ]
        end

        if week1_present != week2_present
          errors << error("incomplete_weekly_hours", "Both Week 1 and Week 2 hours are required before overtime can be calculated.")
        end

        if week1_present && week2_present
          if week1_hours > 168 || week2_hours > 168
            errors << error("weekly_hours_out_of_range", "A legal workweek cannot contain more than 168 hours.")
          end

          regular, overtime = self.class.split_for_weekly_hours(week1_hours, week2_hours)
          weekly_total = (week1_hours + week2_hours).round(2)
          if total_present && !reconciles?(weekly_total, total_hours)
            errors << error("weekly_total_mismatch", "Week 1 + Week 2 hours do not tie to the extracted total hours.")
          end
          if explicit_regular != explicit_overtime
            errors << error("incomplete_overtime_split", "Extracted regular and overtime hours must be supplied together.")
          elsif explicit_regular && (!reconciles?(regular, regular_hours) || !reconciles?(overtime, overtime_hours))
            errors << error("overtime_split_mismatch", "Extracted regular/overtime hours do not match the legal weekly calculation.")
          end

          return [ regular, overtime, errors, [] ]
        end

        supplied_total = if total_present
          total_hours
        elsif explicit_regular || explicit_overtime
          regular_hours + overtime_hours
        else
          0.to_d
        end
        if supplied_total.positive?
          errors << error("weekly_hours_required", "Enter Week 1 and Week 2 hours so Payroll can calculate overtime from the confirmed legal workweek.")
        end
        if explicit_regular != explicit_overtime
          errors << error("incomplete_overtime_split", "Extracted regular and overtime hours must be supplied together.")
        elsif total_present && explicit_regular && !reconciles?(regular_hours + overtime_hours, total_hours)
          errors << error("source_total_mismatch", "Extracted regular + overtime hours do not tie to the extracted total hours.")
        end

        [ total_present ? total_hours : regular_hours, explicit_overtime ? overtime_hours : 0.to_d, errors, [] ]
      end

      def hours_for_total_as_regular_warn_over_threshold(week1_hours:, week2_hours:, total_hours:, regular_hours:, overtime_hours:, week1_present:, week2_present:, total_present:, explicit_regular:, explicit_overtime:)
        if (weekly_frequency? && week1_present) || (week1_present && week2_present)
          return hours_for_weekly_split(
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            total_hours: total_hours,
            regular_hours: regular_hours,
            overtime_hours: overtime_hours,
            week1_present: week1_present,
            week2_present: week2_present,
            total_present: total_present,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime
          )
        end

        errors = []
        warnings = []
        if week1_present != week2_present && !weekly_frequency?
          errors << error("incomplete_weekly_hours", "Both Week 1 and Week 2 hours are required when supplying a weekly breakdown.")
        end
        if explicit_regular != explicit_overtime
          errors << error("incomplete_overtime_split", "Extracted regular and overtime hours must be supplied together.")
        elsif total_present && explicit_regular && !reconciles?(regular_hours + overtime_hours, total_hours)
          errors << error("source_total_mismatch", "Extracted regular + overtime hours do not tie to the extracted total hours.")
        end

        resolved_regular = explicit_regular ? regular_hours : (total_present ? total_hours : 0.to_d)
        resolved_overtime = explicit_overtime ? overtime_hours : 0.to_d
        combined = (resolved_regular + resolved_overtime).round(2)
        threshold = period_regular_hours_threshold

        if !explicit_overtime && combined > threshold
          warnings << warning(
            "hours_exceed_period_threshold",
            "Total hours (#{format('%.2f', combined)}) exceed #{format('%.2f', threshold)} for this period without a weekly breakdown. Confirm whether any overtime applies before applying.",
            "warning"
          )
        end

        [ resolved_regular, resolved_overtime, errors, warnings ]
      end

      def hours_for_source_reports(total_hours:, regular_hours:, overtime_hours:, total_present:, explicit_regular:, explicit_overtime:)
        errors = []
        if explicit_regular != explicit_overtime && !total_present
          errors << error("incomplete_overtime_split", "Extracted regular and overtime hours must be supplied together.")
        elsif total_present && explicit_regular && explicit_overtime && !reconciles?(regular_hours + overtime_hours, total_hours)
          errors << error("source_total_mismatch", "Extracted regular + overtime hours do not tie to the extracted total hours.")
        end

        resolved_regular = explicit_regular ? regular_hours : (total_present ? total_hours : 0.to_d)
        resolved_overtime = explicit_overtime ? overtime_hours : 0.to_d
        [ resolved_regular, resolved_overtime, errors, [] ]
      end

      def hours_for_daily_records(daily_hours:, week1_hours:, week2_hours:, total_hours:, regular_hours:, overtime_hours:, week1_present:, week2_present:, total_present:, explicit_regular:, explicit_overtime:)
        entries = Array(daily_hours).select { |entry| entry.is_a?(Hash) }
        if entries.any?
          return split_from_daily_records(entries, total_hours: total_hours, total_present: total_present)
        end

        if (weekly_frequency? && week1_present) || (week1_present && week2_present)
          return hours_for_weekly_split(
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            total_hours: total_hours,
            regular_hours: regular_hours,
            overtime_hours: overtime_hours,
            week1_present: week1_present,
            week2_present: week2_present,
            total_present: total_present,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime
          )
        end

        errors = []
        supplied_total = total_present ? total_hours : (regular_hours + overtime_hours)
        if supplied_total.positive?
          errors << error("daily_hours_required", "Provide daily hours records or Week 1 and Week 2 hours so Payroll can calculate overtime from the confirmed legal workweek.")
        end
        [ total_present ? total_hours : regular_hours, explicit_overtime ? overtime_hours : 0.to_d, errors, [] ]
      end

      def split_from_daily_records(entries, total_hours:, total_present:)
        errors = []
        workweek = pay_period.resolved_company_workweek
        start_weekday = workweek&.starts_on_weekday || pay_period.start_date.wday
        weekly_buckets = Hash.new(0.to_d)
        entries.each do |entry|
          data = entry.with_indifferent_access
          date = parse_date(data[:date])
          hours = decimal(data[:hours])
          unless date && date.between?(pay_period.start_date, pay_period.end_date)
            errors << error("daily_hours_out_of_period", "Daily hours date #{data[:date]} falls outside this pay period.")
            next
          end
          offset = (date.wday - start_weekday) % 7
          week_start = date - offset
          weekly_buckets[week_start] += hours
        end

        regular = 0.to_d
        overtime = 0.to_d
        weekly_buckets.each_value do |hours|
          if hours > 168
            errors << error("weekly_hours_out_of_range", "A legal workweek cannot contain more than 168 hours.")
          end
          regular += [ hours, BigDecimal(HOURS_PER_WEEK_BEFORE_OT.to_s) ].min
          overtime += [ hours - BigDecimal(HOURS_PER_WEEK_BEFORE_OT.to_s), 0.to_d ].max
        end

        summed = (regular + overtime).round(2)
        if total_present && !reconciles?(summed, total_hours)
          errors << error("daily_total_mismatch", "Daily hours do not tie to the extracted total hours.")
        end

        [ regular.round(2), overtime.round(2), errors, [] ]
      end

      def decimal(value)
        return 0.to_d if value.blank?

        BigDecimal(value.to_s.gsub(/[$,]/, ""))
      rescue ArgumentError
        0.to_d
      end

      def money_decimal(value)
        decimal(value).round(2)
      end

      def parse_optional_boolean(value)
        return value if value == true || value == false
        return nil if value.nil? || value.to_s.strip.empty?

        ActiveModel::Type::Boolean.new.cast(value)
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
