# frozen_string_literal: true

require "bigdecimal"

module PayrollIntake
  module Adapters
    # Universal "Cornerstone workbook" intake adapter (Track C B8-B9).
    #
    # Accepts either the generated XLSX or CSV template with identical columns:
    # hours (weekly or source-reported regular/OT), PTO, holiday, tips, bonuses,
    # one-time items, and loans. Matches strictly by Employee ID — never by name.
    class CornerstoneWorkbook
      DESCRIPTOR_PATH = Rails.root.join("config/payroll_intake/cornerstone_workbook.yml")
      DESCRIPTOR = PayrollIntake::Descriptor.from_yaml(DESCRIPTOR_PATH, adapter_class: self)
      PARSER_VERSION = DESCRIPTOR.parser_version
      SOURCE_TYPE = DESCRIPTOR.key
      SOURCE_LABEL = DESCRIPTOR.source_label
      SOURCE_ROLES = DESCRIPTOR.source_roles
      HOURS_PER_WEEK_BEFORE_OT = BigDecimal("40")
      MAX_HOURS_PER_WEEK = BigDecimal("168")
      RECONCILIATION_TOLERANCE = BigDecimal("0.01")

      def self.descriptor
        DESCRIPTOR
      end

      def self.source_roles
        descriptor.source_roles
      end

      def self.default_required_source_roles
        descriptor.default_required_source_roles
      end

      def self.source_role_for(filename:, content_type:, **)
        descriptor.source_role_for(filename: filename, content_type: content_type)
      end

      def self.reports_overtime?
        descriptor.reports_overtime?
      end

      def self.split_for_weekly_hours(week1_hours, week2_hours)
        weeks = [ week1_hours, week2_hours ].map { |value| BigDecimal(value.to_s.presence || "0") }
        regular = weeks.sum(0.to_d) { |hours| [ hours, HOURS_PER_WEEK_BEFORE_OT ].min }.round(2)
        overtime = weeks.sum(0.to_d) { |hours| [ hours - HOURS_PER_WEEK_BEFORE_OT, 0.to_d ].max }.round(2)
        [ regular, overtime ]
      end

      def initialize(pay_period:, company:)
        @pay_period = pay_period
        @company = company
        @effective_settings = PayrollIntake::EffectiveSettings.for(
          company: company,
          pay_period: pay_period,
          source_type: SOURCE_TYPE
        )
      end

      def extract(files:, pasted_text: nil)
        if pasted_text.present?
          raise ArgumentError, "Cornerstone workbook intake does not accept pasted text. Upload an XLSX or CSV workbook."
        end

        workbook_files = Array(files).select { |file| workbook_file?(file) }
        unsupported = Array(files) - workbook_files
        if unsupported.any? || workbook_files.empty? || workbook_files.many?
          raise ArgumentError, "Upload exactly one Cornerstone workbook (.xlsx or .csv)."
        end

        parsed = PayrollIntake::UniversalWorkbook::Parser.parse_file(
          workbook_files.first,
          company: company,
          pay_period: pay_period
        )

        {
          rows: parsed.fetch(:rows),
          detected_period: {
            start_date: pay_period.start_date.iso8601,
            end_date: pay_period.end_date.iso8601,
            pay_date: pay_period.pay_date.iso8601,
            workbook: parsed.fetch(:metadata, {})
          },
          warnings: Array(parsed[:warnings]),
          trusted_source: true
        }
      end

      def normalize(extracted_rows:, detected_period: nil, trusted_source: true)
        active_by_id = company.employees.active.preload(:employee_compensation_changes).index_by(&:id)
        non_active_by_id = company.employees.where.not(status: "active").index_by(&:id)

        raw_list = Array(extracted_rows).map { |row| row.with_indifferent_access }
        duplicate_ids = raw_list
          .filter_map { |row| row[:employee_id].presence&.to_i }
          .tally
          .select { |_id, count| count > 1 }
          .keys
          .to_set

        rows = raw_list.each_with_index.map do |raw_row, index|
          normalize_row(
            raw_row,
            index,
            active_by_id: active_by_id,
            non_active_by_id: non_active_by_id,
            duplicate_ids: duplicate_ids
          )
        end

        totals = {
          row_count: rows.length,
          ready_count: rows.count { |row| row[:status] == "ready" },
          review_count: rows.count { |row| row[:status] == "needs_review" },
          total_regular_hours: sum_decimal(rows) { |row| row[:regular_hours] }.to_s("F"),
          total_overtime_hours: sum_decimal(rows) { |row| row[:overtime_hours] }.to_s("F"),
          total_pto_hours: sum_decimal(rows) { |row| row.dig(:source_payload, "pto_hours") }.to_s("F"),
          total_holiday_hours: sum_decimal(rows) { |row| row.dig(:source_payload, "holiday_hours") }.to_s("F"),
          total_reported_tips: sum_decimal(rows) { |row| row[:reported_tips] }.to_s("F"),
          total_tips_paid_out: sum_decimal(rows) { |row| row[:tips_paid_out] }.to_s("F"),
          total_bonus: sum_decimal(rows) { |row| row.dig(:source_payload, "bonus") }.to_s("F"),
          total_loan_deductions: sum_decimal(rows) { |row| row[:loan_deduction] }.to_s("F")
        }

        evidence = {
          "source_period" => {
            "start_date" => pay_period.start_date.iso8601,
            "end_date" => pay_period.end_date.iso8601
          },
          "workbook" => detected_period.to_h.deep_stringify_keys,
          "pay_frequency" => pay_frequency,
          "overtime_mode" => effective_settings.overtime_mode,
          "tip_treatment" => {
            "default" => effective_settings.tips_default,
            "source" => effective_settings.source
          }
        }

        { rows: rows, warnings: [], totals: totals, evidence: evidence }
      end

      private

      attr_reader :pay_period, :company, :effective_settings

      def workbook_file?(file)
        ext = File.extname(file.respond_to?(:original_filename) ? file.original_filename.to_s : file.path.to_s).downcase
        ext.in?(%w[.xlsx .csv])
      end

      def pay_frequency
        @pay_frequency ||= pay_period.company_pay_schedule&.frequency.presence ||
          company.pay_frequency.to_s.presence ||
          "biweekly"
      end

      def weekly_frequency?
        pay_frequency == "weekly"
      end

      def normalize_row(raw_row, index, active_by_id:, non_active_by_id:, duplicate_ids:)
        row_num = raw_row[:row_number] || (index + 2)
        errors = Array(raw_row[:parse_errors]).map { |entry| entry.to_h.symbolize_keys }
        warnings = []

        employee_id = raw_row[:employee_id].presence&.to_i
        matched_employee = employee_id ? active_by_id[employee_id] : nil

        if employee_id && matched_employee.nil?
          inactive = non_active_by_id[employee_id]
          if inactive
            errors << error(
              "inactive_employee_id",
              "Row #{row_num}: Employee ID #{employee_id} (#{inactive.full_name}) is #{inactive.status} in Cornerstone."
            )
          else
            errors << error(
              "unmatched_employee_id",
              "Row #{row_num}: Employee ID #{employee_id} does not match an active employee in this company."
            )
          end
        end

        if employee_id && duplicate_ids.include?(employee_id)
          errors << error(
            "duplicate_employee_id",
            "Row #{row_num}: Multiple workbook rows use Employee ID #{employee_id}. Combine them into one row before applying."
          )
        end

        week1_present = !raw_row[:week1_hours].nil?
        week2_present = !raw_row[:week2_hours].nil?
        regular_present = !raw_row[:regular_hours].nil?
        overtime_present = !raw_row[:overtime_hours].nil?

        week1_hours = to_decimal(raw_row[:week1_hours])
        week2_hours = to_decimal(raw_row[:week2_hours])
        explicit_regular = to_decimal(raw_row[:regular_hours])
        explicit_overtime = to_decimal(raw_row[:overtime_hours])

        regular_hours, overtime_hours, hour_errors, hour_warnings = resolve_hours(
          row_num: row_num,
          week1_hours: week1_hours,
          week2_hours: week2_hours,
          explicit_regular: explicit_regular,
          explicit_overtime: explicit_overtime,
          week1_present: week1_present,
          week2_present: week2_present,
          regular_present: regular_present,
          overtime_present: overtime_present
        )
        errors.concat(hour_errors)
        warnings.concat(hour_warnings)

        pto_hours = to_decimal(raw_row[:pto_hours])
        holiday_hours = to_decimal(raw_row[:holiday_hours])
        tips = to_decimal(raw_row[:tips])
        bonus = raw_row[:bonus].nil? ? nil : to_decimal(raw_row[:bonus])
        loan_deduction = to_decimal(raw_row[:loan_deduction])

        row_tips_override = raw_row[:tips_already_paid]
        tips_already_paid = row_tips_override.nil? ? effective_settings.tips_already_paid_default? : (row_tips_override == true)
        tip_treatment_source = row_tips_override.nil? ? effective_settings.source : "row_override"
        tips_paid_out = tips_already_paid ? tips : 0.to_d

        if matched_employee
          errors.concat(
            contractor_field_errors(
              row_num: row_num,
              employee: matched_employee,
              week1_hours: week1_hours,
              week2_hours: week2_hours,
              regular_hours: regular_hours,
              overtime_hours: overtime_hours,
              pto_hours: pto_hours,
              holiday_hours: holiday_hours,
              tips: tips,
              tips_paid_out: tips_paid_out
            )
          )
        end

        serialized_components = Array(raw_row[:payroll_components]).map do |component|
          data = component.to_h.deep_stringify_keys
          data["amount"] = to_decimal(data["amount"]).to_s("F")
          data["effective_pay_date"] ||= pay_period.pay_date.iso8601
          data
        end

        display_name = matched_employee&.full_name ||
          raw_row[:employee_name].presence ||
          (employee_id ? "Employee ID #{employee_id}" : "Row #{row_num}")

        source_payload = {
          "row_number" => row_num,
          "source_employee_id" => raw_row[:raw_employee_id],
          "source_employee_name" => raw_row[:employee_name],
          "pto_hours" => pto_hours.to_s("F"),
          "holiday_hours" => holiday_hours.to_s("F"),
          "bonus" => bonus&.to_s("F"),
          "payroll_components" => serialized_components,
          "notes" => raw_row[:notes],
          "resolved_tip_treatment" => (tips_already_paid ? "already_paid_out" : "paid_in_check"),
          "tip_treatment_source" => tip_treatment_source,
          "resolved_overtime_mode" => effective_settings.overtime_mode,
          "pay_frequency" => pay_frequency
        }.compact

        {
          position: index,
          source_employee_name: display_name,
          employee_id: matched_employee&.id,
          match_method: matched_employee ? "employee_id" : nil,
          match_confidence: matched_employee ? 1.0 : nil,
          confidence: 1.0,
          week1_hours: week1_hours,
          week2_hours: week2_hours,
          regular_hours: regular_hours,
          overtime_hours: overtime_hours,
          week1_tips: 0.to_d,
          week2_tips: 0.to_d,
          reported_tips: tips,
          tips_paid_out: tips_paid_out,
          loan_deduction: loan_deduction,
          warnings: warnings,
          validation_errors: errors,
          status: errors.any? || warnings.any? ? "needs_review" : "ready",
          source_payload: source_payload
        }
      end

      def resolve_hours(row_num:, week1_hours:, week2_hours:, explicit_regular:, explicit_overtime:,
                        week1_present:, week2_present:, regular_present:, overtime_present:)
        case effective_settings.overtime_mode
        when "source_reports"
          resolve_source_reported_hours(
            row_num: row_num,
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime,
            week1_present: week1_present,
            week2_present: week2_present,
            regular_present: regular_present,
            overtime_present: overtime_present
          )
        when "total_as_regular_warn_over_80"
          resolve_warn_over_threshold_hours(
            row_num: row_num,
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime,
            week1_present: week1_present,
            week2_present: week2_present,
            regular_present: regular_present,
            overtime_present: overtime_present
          )
        else
          resolve_weekly_split_hours(
            row_num: row_num,
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime,
            week1_present: week1_present,
            week2_present: week2_present,
            regular_present: regular_present,
            overtime_present: overtime_present
          )
        end
      end

      def resolve_source_reported_hours(row_num:, week1_hours:, week2_hours:, explicit_regular:, explicit_overtime:,
                                        week1_present:, week2_present:, regular_present:, overtime_present:)
        errors = []
        weekly_present = week1_present || week2_present
        weekly_total = (week1_hours + week2_hours).round(2)
        reported_total = (explicit_regular + explicit_overtime).round(2)

        if weekly_present && !regular_present && !overtime_present && weekly_total.positive?
          errors << error(
            "source_overtime_hours_required",
            "Row #{row_num}: Enter Regular Hours and Overtime Hours when overtime mode is source_reports."
          )
          return [ 0.to_d, 0.to_d, errors, [] ]
        end

        if weekly_present && (regular_present || overtime_present) && !reconciles?(weekly_total, reported_total)
          errors << error(
            "conflicting_hours_columns",
            "Row #{row_num}: Week 1 + Week 2 hours (#{format('%.2f', weekly_total)}) do not match " \
            "Regular + Overtime hours (#{format('%.2f', reported_total)}). Clear Week 1/Week 2 Hours or reconcile both totals."
          )
          return [ explicit_regular, explicit_overtime, errors, [] ]
        end

        [ explicit_regular, explicit_overtime, errors, [] ]
      end

      def contractor_field_errors(row_num:, employee:, week1_hours:, week2_hours:, regular_hours:, overtime_hours:,
                                  pto_hours:, holiday_hours:, tips:, tips_paid_out:)
        compensation = employee.payroll_compensation_on(pay_period.end_date)
        return [] unless compensation.employment_type == "contractor"

        errors = []
        if pto_hours.positive?
          errors << error(
            "contractor_unsupported_pto_hours",
            "Row #{row_num}: 1099 contractors cannot receive PTO hours in universal workbook intake " \
            "(got #{format('%.2f', pto_hours)}). Clear PTO Hours before applying."
          )
        end
        if holiday_hours.positive?
          errors << error(
            "contractor_unsupported_holiday_hours",
            "Row #{row_num}: 1099 contractors cannot receive holiday hours in universal workbook intake " \
            "(got #{format('%.2f', holiday_hours)}). Clear Holiday Hours before applying."
          )
        end
        if tips.positive? || tips_paid_out.positive?
          errors << error(
            "contractor_unsupported_tips",
            "Row #{row_num}: 1099 contractors cannot receive employee tips or tip offsets in universal workbook intake " \
            "(got $#{format('%.2f', [ tips, tips_paid_out ].max)}). Clear Tips before applying."
          )
        end
        if compensation.contractor_pay_type != "hourly" &&
          (regular_hours.positive? || overtime_hours.positive? || week1_hours.positive? || week2_hours.positive?)
          errors << error(
            "contractor_unsupported_hours",
            "Row #{row_num}: Flat-fee 1099 contractors cannot receive hourly wages via hours columns. Clear Hours before applying."
          )
        end
        errors
      end

      def resolve_weekly_split_hours(row_num:, week1_hours:, week2_hours:, explicit_regular:, explicit_overtime:,
                                     week1_present:, week2_present:, regular_present:, overtime_present:)
        errors = []

        if weekly_frequency?
          if week2_hours.positive?
            errors << error("week2_not_allowed_on_weekly", "Row #{row_num}: Week 2 Hours must be blank or 0 on a weekly pay schedule.")
          end
          if week1_hours > MAX_HOURS_PER_WEEK
            errors << error("weekly_hours_out_of_range", "Row #{row_num}: A 7-day workweek cannot exceed 168 hours.")
          end

          if week1_present
            regular, overtime = self.class.split_for_weekly_hours(week1_hours, 0.to_d)
            if (regular_present || overtime_present) && (!reconciles?(regular, explicit_regular) || !reconciles?(overtime, explicit_overtime))
              errors << error(
                "overtime_split_mismatch",
                "Row #{row_num}: Entered Regular/Overtime hours do not match the 7-day legal workweek calculation " \
                "(#{format('%.2f', regular)} regular / #{format('%.2f', overtime)} OT)."
              )
            end
            return [ regular, overtime, errors, [] ]
          end

          if (explicit_regular + explicit_overtime).positive?
            errors << error(
              "weekly_hours_required",
              "Row #{row_num}: Enter Week 1 Hours so Payroll can calculate overtime from the complete 7-day workweek (29 CFR 778.104)."
            )
          end
          return [ explicit_regular, explicit_overtime, errors, [] ]
        end

        # Biweekly (two complete 7-day workweeks)
        if week1_hours > MAX_HOURS_PER_WEEK || week2_hours > MAX_HOURS_PER_WEEK
          errors << error("weekly_hours_out_of_range", "Row #{row_num}: A 7-day workweek cannot exceed 168 hours.")
        end

        if week1_present || week2_present
          regular, overtime = self.class.split_for_weekly_hours(week1_hours, week2_hours)
          if (regular_present || overtime_present) && (!reconciles?(regular, explicit_regular) || !reconciles?(overtime, explicit_overtime))
            errors << error(
              "overtime_split_mismatch",
              "Row #{row_num}: Entered Regular/Overtime hours do not match the legal 7-day weekly calculation " \
              "(#{format('%.2f', regular)} regular / #{format('%.2f', overtime)} OT)."
            )
          end
          return [ regular, overtime, errors, [] ]
        end

        if (explicit_regular + explicit_overtime).positive?
          errors << error(
            "weekly_hours_required",
            "Row #{row_num}: Enter Week 1 Hours and Week 2 Hours so Payroll can calculate overtime from each complete 7-day workweek (29 CFR 778.104)."
          )
        end
        [ explicit_regular, explicit_overtime, errors, [] ]
      end

      def resolve_warn_over_threshold_hours(row_num:, week1_hours:, week2_hours:, explicit_regular:, explicit_overtime:,
                                            week1_present:, week2_present:, regular_present:, overtime_present:)
        if week1_present || week2_present
          regular, overtime, errors, warnings = resolve_weekly_split_hours(
            row_num: row_num,
            week1_hours: week1_hours,
            week2_hours: week2_hours,
            explicit_regular: explicit_regular,
            explicit_overtime: explicit_overtime,
            week1_present: week1_present,
            week2_present: week2_present,
            regular_present: regular_present,
            overtime_present: overtime_present
          )
          if week1_hours > HOURS_PER_WEEK_BEFORE_OT || (!weekly_frequency? && week2_hours > HOURS_PER_WEEK_BEFORE_OT)
            warnings << warning(
              "single_week_exceeds_40_hours",
              "Row #{row_num}: At least one 7-day workweek exceeds 40.00 hours. Confirm overtime before applying."
            )
          end
          return [ regular, overtime, errors, warnings ]
        end

        warnings = []
        threshold = weekly_frequency? ? HOURS_PER_WEEK_BEFORE_OT : (HOURS_PER_WEEK_BEFORE_OT * 2)
        combined = (explicit_regular + explicit_overtime).round(2)
        if explicit_overtime.zero? && combined > threshold
          warnings << warning(
            "hours_exceed_period_threshold",
            "Row #{row_num}: Total hours (#{format('%.2f', combined)}) exceed #{format('%.2f', threshold)} without a weekly breakdown. Confirm whether overtime applies."
          )
        end

        [ explicit_regular, explicit_overtime, [], warnings ]
      end

      def to_decimal(value)
        return 0.to_d if value.nil? || (value.is_a?(String) && value.strip.empty?)

        BigDecimal(value.to_s).round(2)
      end

      def sum_decimal(rows)
        rows.sum(0.to_d) { |row| to_decimal(yield(row)) }.round(2)
      end

      def reconciles?(left, right)
        (to_decimal(left) - to_decimal(right)).abs <= RECONCILIATION_TOLERANCE
      end

      def error(code, message)
        { code: code, message: message, severity: "error" }
      end

      def warning(code, message)
        { code: code, message: message, severity: "warning" }
      end
    end
  end
end
