# frozen_string_literal: true

require "bigdecimal"
require "csv"
require "roo"
require "tempfile"

module PayrollIntake
  module UniversalWorkbook
    # Strictly parses both XLSX and CSV Cornerstone universal workbooks.
    #
    # Design guarantees:
    # - BigDecimal end-to-end for all hours and money (never silent Float coercion).
    # - Strict YES/NO/blank parsing for Tips Already Paid (no truthy-string booleans).
    # - Negative hours and negative amounts are rejected with clear row-level errors.
    # - Malformed cells produce actionable row-level errors rather than crashing.
    class Parser
      STRICT_NUMBER_PATTERN = /\A[+-]?(?:\d+(?:\.\d+)?|\.\d+)\z/
      GROUPED_MONEY_PATTERN = /\A[+-]?\d{1,3}(?:,\d{3})+(?:\.\d+)?\z/

      HEADER_MAP = {
        "employee id" => :employee_id,
        "employee" => :employee_name,
        "week 1 hours" => :week1_hours,
        "week 2 hours" => :week2_hours,
        "regular hours" => :regular_hours,
        "overtime hours" => :overtime_hours,
        "pto hours" => :pto_hours,
        "holiday hours" => :holiday_hours,
        "tips" => :tips,
        "tips already paid (yes/no)" => :tips_already_paid,
        "tips already paid" => :tips_already_paid,
        "bonus" => :bonus,
        "one-time item type" => :one_time_item_type,
        "one-time item label" => :one_time_item_label,
        "one-time item amount" => :one_time_item_amount,
        "loan deduction" => :loan_deduction,
        "notes" => :notes
      }.freeze

      INPUT_FIELDS = %i[
        week1_hours week2_hours regular_hours overtime_hours
        pto_hours holiday_hours tips tips_already_paid bonus
        one_time_item_type one_time_item_label one_time_item_amount
        loan_deduction notes
      ].freeze

      HOUR_FIELDS = {
        week1_hours: "Week 1 Hours",
        week2_hours: "Week 2 Hours",
        regular_hours: "Regular Hours",
        overtime_hours: "Overtime Hours",
        pto_hours: "PTO Hours",
        holiday_hours: "Holiday Hours"
      }.freeze

      MONEY_FIELDS = {
        tips: "Tips",
        bonus: "Bonus",
        loan_deduction: "Loan Deduction"
      }.freeze

      COMPONENT_TYPES = PayrollImport::LoanTipExcelParser::GENERATED_COMPONENT_TYPES

      class << self
        def parse_file(file, company: nil, pay_period: nil)
          filename = file.respond_to?(:original_filename) ? file.original_filename.to_s : File.basename(file.path.to_s)
          ext = File.extname(filename).downcase
          unless ext.in?(%w[.xlsx .csv])
            raise ArgumentError, "Cornerstone workbook must be an .xlsx or .csv file."
          end

          if file.respond_to?(:path) && file.path.present? && File.exist?(file.path)
            return new(file.path, extension: ext, company: company, pay_period: pay_period).parse
          end

          tempfile = Tempfile.new([ "cornerstone-workbook", ext ])
          begin
            tempfile.binmode
            io = file.respond_to?(:tempfile) && file.tempfile ? file.tempfile : file
            io.rewind if io.respond_to?(:rewind)
            tempfile.write(io.read)
            io.rewind if io.respond_to?(:rewind)
            tempfile.close
            new(tempfile.path, extension: ext, company: company, pay_period: pay_period).parse
          ensure
            tempfile.unlink if tempfile
          end
        end
      end

      def initialize(file_path, extension: nil, company: nil, pay_period: nil)
        @file_path = file_path.to_s
        @extension = (extension || File.extname(@file_path)).downcase
        @company = company
        @pay_period = pay_period
        raise ArgumentError, "File not found: #{@file_path}" unless File.exist?(@file_path)
        raise ArgumentError, "Cornerstone workbook must be an .xlsx or .csv file." unless @extension.in?(%w[.xlsx .csv])
      end

      def parse
        @extension == ".csv" ? parse_csv : parse_xlsx
      end

      private

      attr_reader :file_path, :extension, :company, :pay_period

      def parse_xlsx
        xlsx = Roo::Spreadsheet.open(file_path, extension: :xlsx)
        metadata = extract_xlsx_metadata(xlsx)
        validate_metadata!(metadata) if metadata.present?

        sheet_name = xlsx.sheets.find { |name| name.to_s.strip.casecmp?(Template::PAYROLL_SHEET) } ||
          xlsx.sheets.find { |name| !name.to_s.strip.casecmp?(Template::START_SHEET) }
        raise ArgumentError, "Workbook is missing the #{Template::PAYROLL_SHEET} sheet." unless sheet_name

        sheet = xlsx.sheet(sheet_name)
        last_row = sheet.last_row.to_i
        raise ArgumentError, "Workbook #{sheet_name} sheet is empty." if last_row < 1

        headers = (1..sheet.last_column.to_i).map { |col| sheet.cell(1, col) }
        column_map = resolve_headers!(headers)

        rows = []
        (2..last_row).each do |row_num|
          values = column_map.transform_values { |col_index| sheet.cell(row_num, col_index + 1) }
          parsed = parse_row(values, row_num: row_num)
          rows << parsed if parsed
        end

        { rows: rows, metadata: metadata.merge(format: "xlsx"), warnings: [] }
      rescue Zip::Error, Roo::Error => e
        raise ArgumentError, "Could not read Excel workbook: #{e.message}"
      end

      def parse_csv
        raw_bytes = File.binread(file_path)
        text = decode_csv_text!(raw_bytes)
        csv_rows = CSV.parse(text)
        raise ArgumentError, "CSV file is empty." if csv_rows.empty?

        column_map = resolve_headers!(csv_rows.first)
        rows = []
        csv_rows.drop(1).each_with_index do |csv_row, offset|
          row_num = offset + 2
          next if csv_row.nil? || csv_row.all? { |cell| cell.to_s.strip.empty? }

          values = column_map.transform_values { |col_index| csv_row[col_index] }
          parsed = parse_row(values, row_num: row_num)
          rows << parsed if parsed
        end

        {
          rows: rows,
          metadata: {
            format: "csv",
            schema_version: Template::SCHEMA_VERSION,
            period_start: pay_period&.start_date&.iso8601,
            period_end: pay_period&.end_date&.iso8601,
            pay_date: pay_period&.pay_date&.iso8601
          }.compact,
          warnings: []
        }
      rescue CSV::MalformedCSVError => e
        raise ArgumentError, "CSV file could not be parsed: #{e.message}"
      end

      def decode_csv_text!(bytes)
        raise ArgumentError, "CSV file is empty." if bytes.empty?

        text = if bytes.start_with?("\xFF\xFE".b)
          bytes.dup.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
        elsif bytes.start_with?("\xFE\xFF".b)
          bytes.dup.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8)
        elsif bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          bytes.dup.force_encoding(Encoding::UTF_8)
        else
          bytes.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
        end
        text = text.delete_prefix("\uFEFF")
        if text.match?(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/)
          raise ArgumentError, "CSV file contains invalid binary or control characters."
        end

        text
      rescue EncodingError
        raise ArgumentError, "CSV file encoding could not be read. Export as UTF-8 CSV or XLSX."
      end

      def extract_xlsx_metadata(xlsx)
        start_name = xlsx.sheets.find { |name| name.to_s.strip.casecmp?(Template::START_SHEET) }
        return {} unless start_name

        sheet = xlsx.sheet(start_name)
        values = (1..sheet.last_row.to_i).each_with_object({}) do |row_num, acc|
          label = normalize_header(sheet.cell(row_num, 1))
          acc[label] = sheet.cell(row_num, 2) if label.present?
        end

        {
          schema_version: values["schema version"].to_s.strip.presence,
          company_id: strict_positive_integer(values["company id"]),
          company_name: values["company"].to_s.strip.presence,
          period_start: parse_date(values["pay period start"]),
          period_end: parse_date(values["pay period end"]),
          pay_date: parse_date(values["pay date"]),
          pay_schedule: values["pay schedule"].to_s.strip.presence,
          overtime_mode: values["overtime mode"].to_s.strip.presence,
          tips_default: values["tip treatment default"].to_s.strip.presence
        }
      end

      def validate_metadata!(metadata)
        schema = metadata[:schema_version]
        if schema.present? && schema != Template::SCHEMA_VERSION
          raise ArgumentError, "Unsupported Cornerstone workbook schema version (#{schema}). Download a fresh template for this payroll."
        end
        if company && metadata[:company_id].present? && metadata[:company_id] != company.id
          raise ArgumentError, "This Cornerstone workbook belongs to another client (Company ID #{metadata[:company_id]}). Download a fresh template for #{company.name}."
        end
        if pay_period
          validate_metadata_date!(metadata[:period_start], pay_period.start_date, "start date")
          validate_metadata_date!(metadata[:period_end], pay_period.end_date, "end date")
          validate_metadata_date!(metadata[:pay_date], pay_period.pay_date, "pay date") if metadata[:pay_date].present?
        end
      end

      def validate_metadata_date!(actual, expected, label)
        return if actual.blank?
        return if actual == expected

        raise ArgumentError,
              "The Cornerstone workbook #{label} is #{actual.iso8601}, but this payroll uses #{expected.iso8601}. Download a fresh template for this pay period."
      end

      def resolve_headers!(raw_headers)
        map = {}
        duplicates = []
        Array(raw_headers).each_with_index do |header, index|
          key = HEADER_MAP[normalize_header(header)]
          next unless key

          if map.key?(key)
            duplicates << header.to_s.strip
          else
            map[key] = index
          end
        end

        raise ArgumentError, "Workbook contains duplicate column header(s): #{duplicates.uniq.join(', ')}." if duplicates.any?
        raise ArgumentError, "Workbook is missing the required 'Employee ID' column." unless map.key?(:employee_id)
        if (map.keys & INPUT_FIELDS).empty?
          raise ArgumentError, "Workbook must include payroll input columns (hours, PTO, holiday, tips, bonuses, one-time items, or loans)."
        end

        map
      end

      def parse_row(values, row_num:)
        return nil if INPUT_FIELDS.all? { |field| cell_blank?(values[field]) }

        row_errors = []
        raw_employee_id = values[:employee_id]
        employee_id = strict_positive_integer(raw_employee_id)
        if cell_blank?(raw_employee_id)
          row_errors << row_error("missing_employee_id", "Row #{row_num}: Employee ID is required.")
        elsif employee_id.nil?
          row_errors << row_error("invalid_employee_id", "Row #{row_num}: Employee ID must be a positive whole number (got #{raw_employee_id.inspect}).")
        end

        employee_name = values[:employee_name].to_s.strip.presence

        parsed_hours = {}
        HOUR_FIELDS.each do |field, label|
          value, error_entry = parse_nonnegative_decimal(values[field], row_num: row_num, field: field, label: label, money: false)
          parsed_hours[field] = value
          row_errors << error_entry if error_entry
        end

        parsed_money = {}
        MONEY_FIELDS.each do |field, label|
          value, error_entry = parse_nonnegative_decimal(values[field], row_num: row_num, field: field, label: label, money: true)
          parsed_money[field] = value
          row_errors << error_entry if error_entry
        end

        tips_already_paid, tip_bool_error = parse_strict_yes_no(values[:tips_already_paid], row_num: row_num)
        row_errors << tip_bool_error if tip_bool_error

        components, component_errors = parse_one_time_item(values, row_num: row_num)
        row_errors.concat(component_errors)

        {
          row_number: row_num,
          employee_id: employee_id,
          raw_employee_id: raw_employee_id.is_a?(String) ? raw_employee_id.strip : raw_employee_id,
          employee_name: employee_name,
          week1_hours: parsed_hours[:week1_hours],
          week2_hours: parsed_hours[:week2_hours],
          regular_hours: parsed_hours[:regular_hours],
          overtime_hours: parsed_hours[:overtime_hours],
          pto_hours: parsed_hours[:pto_hours],
          holiday_hours: parsed_hours[:holiday_hours],
          tips: parsed_money[:tips],
          tips_already_paid: tips_already_paid,
          bonus: parsed_money[:bonus],
          loan_deduction: parsed_money[:loan_deduction],
          payroll_components: components,
          notes: values[:notes].to_s.strip.presence,
          parse_errors: row_errors
        }
      end

      def parse_one_time_item(values, row_num:)
        raw_type = values[:one_time_item_type]
        raw_label = values[:one_time_item_label]
        raw_amount = values[:one_time_item_amount]
        return [ [], [] ] if cell_blank?(raw_type) && cell_blank?(raw_label) && cell_blank?(raw_amount)

        errors = []
        type_token = raw_type.to_s.strip.upcase
        rule = COMPONENT_TYPES[type_token]
        if type_token.empty?
          errors << row_error("missing_one_time_item_type", "Row #{row_num}: One-Time Item Type is required when entering a one-time item.")
        elsif rule.nil?
          errors << row_error(
            "invalid_one_time_item_type",
            "Row #{row_num}: Unsupported One-Time Item Type #{raw_type.inspect}. Allowed: #{COMPONENT_TYPES.keys.join(', ')}."
          )
        end

        amount, amount_error = parse_nonnegative_decimal(raw_amount, row_num: row_num, field: :one_time_item_amount, label: "One-Time Item Amount", money: true)
        if amount_error
          errors << amount_error
        elsif amount.nil? || !amount.positive?
          errors << row_error("invalid_one_time_item_amount", "Row #{row_num}: One-Time Item Amount must be greater than zero.")
        end

        return [ [], errors ] if errors.any?

        label = raw_label.to_s.strip.presence || rule.fetch(:default_label)
        component = {
          component_type: type_token,
          label: label,
          amount: amount,
          kind: rule.fetch(:kind),
          tax_treatment: rule.fetch(:tax_treatment),
          category: rule.fetch(:default_category),
          reporting_group: nil,
          payee_name: rule.fetch(:kind) == "deduction" ? label : nil,
          effective_pay_date: pay_period&.pay_date&.iso8601,
          source: "cornerstone_workbook",
          notes: values[:notes].to_s.strip.presence
        }

        [ [ component ], [] ]
      end

      def parse_nonnegative_decimal(raw, row_num:, field:, label:, money:)
        return [ nil, nil ] if cell_blank?(raw)

        if raw == true || raw == false
          return [ nil, row_error("invalid_#{field}", "Row #{row_num}: #{label} must be a non-negative number, not a boolean (#{raw.inspect}).") ]
        end

        parsed = case raw
        when Integer
          BigDecimal(raw.to_s)
        when BigDecimal
          raw
        when Float
          return [ nil, row_error("invalid_#{field}", "Row #{row_num}: #{label} must be a finite non-negative number.") ] unless raw.finite?

          BigDecimal(raw.to_s)
        when String
          parse_strict_decimal_string(raw, money: money)
        else
          nil
        end

        if parsed.nil? || !parsed.finite?
          return [ nil, row_error("invalid_#{field}", "Row #{row_num}: #{label} must be a valid non-negative number (got #{raw.inspect}).") ]
        end

        if parsed.negative?
          code = HOUR_FIELDS.key?(field) ? "negative_hours" : "negative_amount"
          return [ nil, row_error(code, "Row #{row_num}: #{label} cannot be negative (got #{parsed.to_s('F')}).") ]
        end

        [ parsed.round(2), nil ]
      end

      def parse_strict_decimal_string(raw, money:)
        cleaned = raw.strip
        return nil if cleaned.empty?

        if money
          cleaned = cleaned.sub(/\A\$/, "").strip
          if cleaned.include?(",")
            return nil unless cleaned.match?(GROUPED_MONEY_PATTERN)

            cleaned = cleaned.delete(",")
          end
        end

        return nil unless cleaned.match?(STRICT_NUMBER_PATTERN)

        BigDecimal(cleaned, exception: false)
      end

      def parse_strict_yes_no(raw, row_num:)
        return [ nil, nil ] if cell_blank?(raw)

        if raw.is_a?(String)
          token = raw.strip.upcase
          return [ true, nil ] if token == "YES"
          return [ false, nil ] if token == "NO"
        end

        [
          nil,
          row_error(
            "invalid_tips_already_paid",
            "Row #{row_num}: Tips Already Paid must be YES, NO, or blank (got #{raw.inspect})."
          )
        ]
      end

      def strict_positive_integer(raw)
        return nil if cell_blank?(raw) || raw == true || raw == false

        case raw
        when Integer
          raw.positive? ? raw : nil
        when BigDecimal
          return nil unless raw.finite? && raw.positive? && raw.frac.zero?

          raw.to_i
        when Float
          return nil unless raw.finite? && raw.positive? && (raw % 1).zero?

          raw.to_i
        when String
          token = raw.strip
          return token.to_i if token.match?(/\A[1-9]\d*\z/)

          nil
        else
          nil
        end
      end

      def parse_date(value)
        return nil if cell_blank?(value)
        return value if value.is_a?(Date) && !value.is_a?(DateTime)
        return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

        Date.iso8601(value.to_s.strip)
      rescue Date::Error
        begin
          Date.parse(value.to_s.strip)
        rescue Date::Error
          nil
        end
      end

      def cell_blank?(value)
        return true if value.nil?
        return value.strip.empty? if value.is_a?(String)

        false
      end

      def normalize_header(value)
        value.to_s.strip.downcase.gsub(/\s+/, " ")
      end

      def row_error(code, message)
        { code: code, message: message, severity: "error" }
      end
    end
  end
end
