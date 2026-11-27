# frozen_string_literal: true

module PayrollIntake
  module Adapters
    class MosaRevel
      DESCRIPTOR_PATH = Rails.root.join("config/payroll_intake/mosa_revel.yml")
      DESCRIPTOR = PayrollIntake::Descriptor.from_yaml(DESCRIPTOR_PATH, adapter_class: self)
      PARSER_VERSION = DESCRIPTOR.parser_version
      SOURCE_TYPE = DESCRIPTOR.key
      SOURCE_LABEL = DESCRIPTOR.source_label
      SOURCE_ROLES = DESCRIPTOR.source_roles

      def self.descriptor
        DESCRIPTOR
      end

      def self.source_roles
        descriptor.source_roles
      end

      # Each file can arrive on its own; a package is applied only once both
      # are present, or staff record that there are no tips or loans.
      def self.default_required_source_roles
        descriptor.default_required_source_roles
      end

      def self.source_role_for(filename:, content_type:, **)
        descriptor.source_role_for(filename: filename, content_type: content_type)
      end

      # Revel splits regular and overtime hours itself.
      def self.reports_overtime?
        descriptor.reports_overtime?
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
        raise ArgumentError, "MoSa intake does not accept pasted text. Upload the original Revel PDF, the change workbook, or both." if pasted_text.present?

        pdf_files = files.select { |file| pdf?(file) }
        workbook_files = files.select { |file| workbook?(file) }
        unsupported = files - pdf_files - workbook_files
        if unsupported.any? || pdf_files.many? || workbook_files.many? || (pdf_files.empty? && workbook_files.empty?)
          raise ArgumentError, "Upload one Revel PDF, one Cornerstone change workbook, or one of each."
        end

        revel = pdf_files.first && PayrollImport::RevelPdfParser.parse_file_with_metadata(pdf_files.first)
        if revel
          validate_revel_period!(revel.dig(:metadata, :period))
          raise ArgumentError, "No employee hours were found in the Revel PDF." if revel.fetch(:rows).empty?
        end

        workbook = workbook_files.first && PayrollImport::LoanTipExcelParser.parse_file_with_metadata(workbook_files.first)
        date_warnings = []
        if workbook
          date_warnings = validate_workbook!(workbook.fetch(:metadata, {}))
          validate_supported_workbook_rows!(workbook.fetch(:rows))
        end

        preview = PayrollImport::ImportService.new(pay_period).preview(
          pdf_records: revel&.fetch(:rows) || [],
          excel_records: workbook&.fetch(:rows, []) || []
        )

        {
          rows: tagged_rows(preview, workbook_rows: workbook&.fetch(:rows, []) || []),
          detected_period: {
            revel: revel&.dig(:metadata, :period),
            workbook: workbook&.fetch(:metadata, {}) || {},
            preview: preview.except(:matched)
          },
          warnings: workbook_warnings(workbook) + date_warnings
        }
      end

      def normalize(extracted_rows:, detected_period: nil)
        evidence = detected_period.to_h.deep_stringify_keys
        duplicate_ids = Array(evidence.dig("preview", "duplicate_employee_matches")).filter_map { |match| match["employee_id"] }.map(&:to_i)
        low_confidence_ids = Array(evidence.dig("preview", "low_confidence_matches")).filter_map { |match| match["employee_id"] }.map(&:to_i)

        rows = Array(extracted_rows).each_with_index.map do |raw_row, index|
          normalize_row(
            raw_row.with_indifferent_access,
            index,
            duplicate_ids: duplicate_ids,
            low_confidence_ids: low_confidence_ids
          )
        end
        totals = {
          row_count: rows.length,
          ready_count: rows.count { |row| row[:status] == "ready" },
          review_count: rows.count { |row| row[:status] == "needs_review" },
          total_regular_hours: round(rows.sum { |row| row[:regular_hours].to_f }),
          total_overtime_hours: round(rows.sum { |row| row[:overtime_hours].to_f }),
          total_reported_tips: money(rows.sum { |row| row[:reported_tips].to_f })
        }

        { rows: rows, warnings: [], totals: totals, evidence: evidence }
      end

      private

      attr_reader :pay_period, :company, :effective_settings

      def pdf?(file)
        content_type(file) == "application/pdf" || extension(file) == ".pdf"
      end

      def workbook?(file)
        extension(file).in?(%w[.xls .xlsx])
      end

      def extension(file)
        File.extname(file.respond_to?(:original_filename) ? file.original_filename.to_s : file.path.to_s).downcase
      end

      def content_type(file)
        file.respond_to?(:content_type) ? file.content_type.to_s : ""
      end

      def validate_revel_period!(period)
        raise ArgumentError, "The Revel PDF filename or report must show the full pay-period start and end dates." unless period.is_a?(Hash)

        start_date = Date.parse(period[:start_date] || period["start_date"])
        end_date = Date.parse(period[:end_date] || period["end_date"])
        return if start_date == pay_period.start_date && end_date == pay_period.end_date

        raise ArgumentError,
              "Revel covers #{start_date.iso8601}–#{end_date.iso8601}, but this payroll covers " \
              "#{pay_period.start_date.iso8601}–#{pay_period.end_date.iso8601}. Upload the matching report."
      rescue Date::Error
        raise ArgumentError, "The Revel PDF contains invalid pay-period dates."
      end

      def validate_workbook!(metadata)
        metadata = metadata.to_h.symbolize_keys
        if PayrollImport::MosaSupplementalTemplate::SUPPORTED_SCHEMA_VERSIONS.include?(metadata[:schema_version])
          raise ArgumentError, "The change workbook belongs to another Cornerstone client." unless metadata[:company_id].to_i == company.id
          raise ArgumentError, "The change workbook must include its attestation." if metadata[:attestation].blank?
          validate_date!(metadata[:period_start], pay_period.start_date, "start")
          validate_date!(metadata[:period_end], pay_period.end_date, "end")
          validate_date!(metadata[:pay_date], pay_period.pay_date, "pay date")
          return []
        end

        validate_date!(metadata[:pay_date], pay_period.pay_date, "pay date")
        legacy_period_end_warnings(metadata[:period_end])
      end

      # MoSa's own template has typed the period end a day before Revel's
      # (10/31 vs 11/01). With the pay date matching, keep Revel's dates and
      # ask them to correct the template; a larger gap is a different payroll.
      def legacy_period_end_warnings(period_end)
        raise ArgumentError, "The change workbook must include the pay-period end." if period_end.blank?
        return [] if period_end.to_date == pay_period.end_date
        unless (period_end.to_date - pay_period.end_date).abs <= 1
          raise ArgumentError,
                "The change workbook end is #{period_end.to_date.iso8601}, but this payroll uses #{pay_period.end_date.iso8601}. Upload the workbook for this payroll."
        end

        [
          warning(
            "workbook_period_end_differs",
            "The workbook says the period ends #{period_end.to_date.strftime('%-m/%-d/%Y')}, but Revel and this payroll end " \
            "#{pay_period.end_date.strftime('%-m/%-d/%Y')}. The pay date matches, so this payroll's dates are used. " \
            "Update the template's period end to match Revel."
          )
        ]
      end

      def validate_supported_workbook_rows!(rows)
        named_component_change = rows.find do |row|
          row[:component_reference].present? && row[:loan_deduction].to_f.positive?
        end
        return unless named_component_change

        raise ArgumentError,
              "The change workbook includes a payroll amount for a named recurring or loan component. Review that setup in Cornerstone first, then download a fresh workbook."
      end

      def validate_date!(actual, expected, label)
        raise ArgumentError, "The change workbook must include the pay-period #{label}." if actual.blank?
        return if actual.to_date == expected

        raise ArgumentError,
              "The change workbook #{label} is #{actual.to_date.iso8601}, but this payroll uses #{expected.iso8601}. Download a fresh template."
      end

      def workbook_warnings(workbook)
        return [] unless workbook
        return [] if PayrollImport::MosaSupplementalTemplate::SUPPORTED_SCHEMA_VERSIONS.include?(workbook.dig(:metadata, :schema_version))

        [
          warning(
            "legacy_mosa_workbook",
            "This is the legacy MoSa workbook. It was retained and validated, but use the generated change-only template next payroll for stable employee IDs."
          )
        ]
      end

      def tagged_rows(preview, workbook_rows:)
        matched = preview.fetch(:matched).map { |row| row.merge(row_kind: "matched", preview_row: row) }
        unmatched_pdf = preview.fetch(:unmatched_pdf_names).map { |name| { row_kind: "unmatched_revel", source_employee_name: name } }
        unmatched_workbook = preview.fetch(:unmatched_excel_names).map do |name|
          source = workbook_rows.find do |row|
            (row[:employee_name].presence || [ row[:first_name], row[:last_name] ].compact.join(" ").strip) == name
          end
          {
            row_kind: "unmatched_workbook", source_employee_name: name,
            source_employee_id: source&.dig(:employee_id),
            source_first_name: source&.dig(:first_name), source_last_name: source&.dig(:last_name)
          }
        end
        matched + unmatched_pdf + unmatched_workbook
      end

      def normalize_row(raw_row, index, duplicate_ids:, low_confidence_ids:)
        kind = raw_row[:row_kind]
        name = raw_row[:source_employee_name].presence || raw_row[:pdf_employee_name].presence || raw_row[:employee_name].presence
        errors = []
        warnings = []

        case kind
        when "unmatched_revel"
          errors << unmatched_employee_error(raw_row, name, "unmatched_revel_employee", "Match this Revel hours row to a Cornerstone employee.")
        when "unmatched_workbook"
          errors << unmatched_employee_error(raw_row, name, "unmatched_workbook_employee", "Use the employee's Cornerstone ID in the change workbook.")
        end
        errors.concat(PayrollImport::RevelHoursValidation.errors(raw_row))
        if duplicate_ids.include?(raw_row[:employee_id].to_i)
          errors << error("duplicate_employee", "Multiple Revel rows map to this employee. Resolve the duplicate before applying.")
        end
        if low_confidence_ids.include?(raw_row[:employee_id].to_i)
          warnings << warning("low_confidence_match", "Review the suggested source-name match before applying.")
        end
        Array(raw_row[:loan_reconciliation_errors]).each do |message|
          errors << error("loan_reconciliation_required", message)
        end
        Array(raw_row[:loan_reconciliation_warnings]).each do |message|
          warnings << warning("loan_reconciliation_notice", message)
        end

        regular_hours = round(raw_row[:regular_hours])
        overtime_hours = round(raw_row[:overtime_hours])
        total_tips = money(raw_row[:total_tips])
        row_tips_already_paid = raw_row[:tips_already_paid].nil? ? effective_settings.tips_already_paid_default? : (raw_row[:tips_already_paid] == true)
        tips_paid_out = row_tips_already_paid ? total_tips : 0.0

        {
          position: index,
          source_employee_name: name.to_s.strip.presence || "Unknown source row",
          employee_id: raw_row[:employee_id],
          match_method: raw_row[:payroll_setup_only] ? "payroll_setup" : (raw_row[:matched_name].present? ? "mosa_name_match" : nil),
          match_confidence: raw_row[:confidence],
          confidence: raw_row[:confidence],
          week1_hours: 0,
          week2_hours: 0,
          regular_hours: regular_hours,
          overtime_hours: overtime_hours,
          week1_tips: money(raw_row[:tips_boh]),
          week2_tips: money(raw_row[:tips_foh]),
          reported_tips: total_tips,
          tips_paid_out: tips_paid_out,
          loan_deduction: money(raw_row[:loan_deduction]),
          warnings: warnings,
          validation_errors: errors,
          status: errors.any? || warnings.any? ? "needs_review" : "ready",
          source_payload: raw_row.to_h
        }
      end

      # This lookup only explains an unmatched row; it must never populate the
      # payable employee_id. Only active workers participate in ImportService.
      def unmatched_employee_error(raw_row, name, code, fallback)
        @non_active_employees ||= company.employees.where(status: EmployeeStatusTransitionService::REACTIVATABLE_STATUSES).to_a
        @non_active_matcher ||= PayrollImport::NameMatcher.new(@non_active_employees)
        match = if raw_row[:source_employee_id].present?
          employee = @non_active_employees.find { |candidate| candidate.id == raw_row[:source_employee_id].to_i }
          employee && { employee_id: employee.id }
        elsif raw_row[:row_kind] == "unmatched_revel"
          @non_active_matcher.match_pdf_name(name)
        else
          @non_active_matcher.match_excel_name(raw_row[:source_last_name], raw_row[:source_first_name])
        end
        employee = @non_active_employees.find { |candidate| candidate.id == match&.dig(:employee_id) }
        return error(code, fallback) unless employee

        # Import review offers Reactivate to payroll staff (a terminated worker
        # needs someone who can rehire), then matches the same files again.
        error(code, "#{employee.full_name} is #{employee.status} in Cornerstone.")
          .merge(employee_id: employee.id, employee_name: employee.full_name, employee_status: employee.status)
      end

      def round(value)
        BigDecimal(value.to_s.presence || "0").round(2).to_f
      rescue ArgumentError
        0.0
      end

      def money(value)
        round(value)
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
