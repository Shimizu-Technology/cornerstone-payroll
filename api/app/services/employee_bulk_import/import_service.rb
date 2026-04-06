# frozen_string_literal: true

module EmployeeBulkImport
  class ImportService
    MAX_FILE_SIZE = 10.megabytes

    REQUIRED_COLUMNS = %w[first_name last_name employment_type pay_rate].freeze

    VALID_COLUMNS = %w[
      first_name middle_name last_name email ssn
      date_of_birth hire_date employment_type salary_type pay_rate pay_frequency
      filing_status allowances additional_withholding
      w4_dependent_credit w4_step2_multiple_jobs w4_step4a_other_income w4_step4b_deductions
      retirement_rate roth_retirement_rate
      department
      address_line1 address_line2 city state zip phone
      contractor_type contractor_pay_type business_name contractor_ein w9_on_file
    ].freeze

    BOOLEAN_COLUMNS = %w[w4_step2_multiple_jobs w9_on_file].freeze
    INTEGER_COLUMNS = %w[allowances].freeze
    NUMERIC_COLUMNS = %w[
      pay_rate additional_withholding
      w4_dependent_credit w4_step4a_other_income w4_step4b_deductions
      retirement_rate roth_retirement_rate
    ].freeze
    DATE_COLUMNS = %w[date_of_birth hire_date].freeze

    attr_reader :company, :errors

    def initialize(company)
      @company = company
      @errors = []
    end

    def parse(file)
      rows = read_file(file)
      return { rows: [], errors: @errors } if @errors.any?

      headers = normalize_headers(rows.first)
      validate_headers(headers)
      return { rows: [], errors: @errors } if @errors.any?

      departments = company.departments.index_by { |d| d.name.downcase.strip }
      existing_employees = company.employees.pluck(:first_name, :last_name).map { |f, l| "#{f.downcase.strip} #{l.downcase.strip}" }.to_set
      seen_in_file = Set.new

      parsed_rows = rows.drop(1).each_with_index.map do |row, idx|
        result = parse_row(row, headers, idx + 2, departments, existing_employees, seen_in_file)
        if result
          name_key = "#{result[:raw]['first_name']&.downcase&.strip} #{result[:raw]['last_name']&.downcase&.strip}"
          seen_in_file.add(name_key)
        end
        result
      end.compact

      { rows: parsed_rows, errors: @errors }
    end

    def create_employees!(validated_rows)
      results = { created: 0, failed: 0, errors: [] }

      ActiveRecord::Base.transaction do
        dept_cache = company.departments.index_by { |d| d.name.downcase.strip }

        validated_rows.each do |row_data|
          attrs = row_data[:attributes].dup
          dept_name = attrs.delete(:_department_name)

          if dept_name.present? && attrs[:department_id].blank?
            dept_key = dept_name.downcase.strip
            dept = dept_cache[dept_key] || begin
              d = company.departments.find_or_create_by!(name: dept_name)
              dept_cache[dept_key] = d
              d
            rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
              company.departments.find_by!(name: dept_name)
            end
            attrs[:department_id] = dept.id
          end

          employee = company.employees.new(attrs)
          if employee.save
            results[:created] += 1
          else
            results[:failed] += 1
            results[:errors] << { row: row_data[:row_number], messages: employee.errors.full_messages }
          end
        end

        if results[:failed] > 0
          raise ActiveRecord::Rollback
        end
      end

      if results[:failed] > 0
        results[:created] = 0
      end

      results
    end

    def self.template_headers
      %w[
        first_name last_name middle_name email ssn
        date_of_birth hire_date employment_type salary_type pay_rate pay_frequency
        filing_status allowances additional_withholding
        w4_dependent_credit w4_step2_multiple_jobs w4_step4a_other_income w4_step4b_deductions
        retirement_rate roth_retirement_rate
        department
        address_line1 address_line2 city state zip phone
        contractor_type contractor_pay_type business_name contractor_ein w9_on_file
      ]
    end

    def self.template_csv
      require "csv"
      CSV.generate do |csv|
        csv << template_headers
        csv << [
          "John", "Doe", "", "john@example.com", "123-45-6789",
          "1990-01-15", "2024-03-01", "hourly", "", "15.00", "biweekly",
          "single", "0", "0",
          "0", "false", "0", "0",
          "0", "0",
          "Kitchen",
          "123 Main St", "", "Hagatna", "GU", "96910", "671-555-0100",
          "", "", "", "", ""
        ]
      end
    end

    private

    def read_file(file)
      size = file.respond_to?(:size) ? file.size : File.size(file.path)
      if size > MAX_FILE_SIZE
        @errors << "File is too large (max #{MAX_FILE_SIZE / 1.megabyte} MB)"
        return []
      end

      filename = file.respond_to?(:original_filename) ? file.original_filename : file.path
      ext = File.extname(filename).downcase

      case ext
      when ".csv"
        read_csv(file)
      when ".xlsx", ".xls"
        read_excel(file)
      else
        @errors << "Unsupported file format '#{ext}'. Please upload a CSV or Excel (.xlsx) file."
        []
      end
    rescue StandardError => e
      @errors << "Failed to read file: #{e.message}"
      []
    end

    def read_csv(file)
      require "csv"
      content = file.respond_to?(:read) ? file.read : File.read(file.path)
      content = content.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      CSV.parse(content)
    end

    def read_excel(file)
      require "roo"
      path = file.respond_to?(:tempfile) ? file.tempfile.path : file.path
      spreadsheet = Roo::Spreadsheet.open(path)
      sheet = spreadsheet.sheet(0)
      (sheet.first_row..sheet.last_row).map { |i| sheet.row(i).map { |c| c.to_s.strip } }
    end

    def normalize_headers(header_row)
      return [] unless header_row

      header_row.map do |h|
        h.to_s.strip.downcase
          .gsub(/\s+/, "_")
          .gsub(/[^a-z0-9_]/, "")
      end
    end

    def validate_headers(headers)
      missing = REQUIRED_COLUMNS - headers
      if missing.any?
        @errors << "Missing required columns: #{missing.join(', ')}. Required: #{REQUIRED_COLUMNS.join(', ')}"
      end
    end

    def parse_row(row, headers, row_number, departments, existing_employees, seen_in_file)
      return nil if row.nil? || row.all? { |c| c.to_s.strip.empty? }

      data = {}
      headers.each_with_index do |header, idx|
        next unless VALID_COLUMNS.include?(header)
        data[header] = row[idx].to_s.strip
      end

      row_errors = validate_row_data(data)

      attrs = build_attributes(data, departments)
      full_name = "#{data['first_name']&.downcase&.strip} #{data['last_name']&.downcase&.strip}"
      duplicate = existing_employees.include?(full_name) || seen_in_file.include?(full_name)

      new_dept = data["department"].present? && !departments.key?(data["department"].downcase.strip)

      {
        row_number: row_number,
        raw: data,
        attributes: attrs,
        errors: row_errors,
        valid: row_errors.empty?,
        duplicate: duplicate,
        new_department: new_dept
      }
    end

    def validate_row_data(data)
      errors = []

      REQUIRED_COLUMNS.each do |col|
        errors << "#{col} is required" if data[col].blank?
      end

      if data["employment_type"].present? && !Employee::EMPLOYMENT_TYPES.include?(data["employment_type"])
        errors << "employment_type must be one of: #{Employee::EMPLOYMENT_TYPES.join(', ')}"
      end

      if data["salary_type"].present? && !Employee::SALARY_TYPES.include?(data["salary_type"])
        errors << "salary_type must be one of: #{Employee::SALARY_TYPES.join(', ')}"
      end

      if data["pay_rate"].present?
        begin
          rate = BigDecimal(data["pay_rate"])
          errors << "pay_rate must be >= 0" if rate.negative?
        rescue ArgumentError
          errors << "pay_rate must be a number"
        end
      end

      if data["pay_frequency"].present? && !%w[biweekly weekly semimonthly monthly].include?(data["pay_frequency"])
        errors << "pay_frequency must be one of: biweekly, weekly, semimonthly, monthly"
      end

      if data["filing_status"].present? && !%w[single married married_separate head_of_household].include?(data["filing_status"])
        errors << "filing_status must be one of: single, married, married_separate, head_of_household"
      end

      if data["allowances"].present?
        val = Integer(data["allowances"]) rescue nil
        errors << "allowances must be a non-negative integer" if val.nil? || val.negative?
      end

      if data["ssn"].present?
        digits = data["ssn"].gsub(/\D/, "")
        errors << "ssn must be exactly 9 digits" unless digits.length == 9
      end

      if data["employment_type"] == "contractor"
        if data["contractor_type"].present? && !Employee::CONTRACTOR_TYPES.include?(data["contractor_type"])
          errors << "contractor_type must be one of: #{Employee::CONTRACTOR_TYPES.join(', ')}"
        end
        if data["contractor_pay_type"].present? && !Employee::CONTRACTOR_PAY_TYPES.include?(data["contractor_pay_type"])
          errors << "contractor_pay_type must be one of: #{Employee::CONTRACTOR_PAY_TYPES.join(', ')}"
        end
      end

      %w[w4_dependent_credit w4_step4a_other_income w4_step4b_deductions additional_withholding].each do |col|
        next if data[col].blank?
        begin
          val = BigDecimal(data[col])
          errors << "#{col} must be >= 0" if val.negative?
        rescue ArgumentError
          errors << "#{col} must be a number"
        end
      end

      %w[retirement_rate roth_retirement_rate].each do |col|
        next if data[col].blank?
        begin
          val = BigDecimal(data[col])
          unless val >= 0 && val <= 1
            errors << "#{col} must be between 0 and 1 (e.g. 0.05 for 5%)"
          end
        rescue ArgumentError
          errors << "#{col} must be a number between 0 and 1"
        end
      end

      DATE_COLUMNS.each do |col|
        next if data[col].blank?
        begin
          Date.parse(data[col])
        rescue ArgumentError, Date::Error
          errors << "#{col} must be a valid date (YYYY-MM-DD)"
        end
      end

      errors
    end

    def build_attributes(data, departments)
      attrs = {}

      # String fields
      %w[first_name middle_name last_name email address_line1 address_line2 city state zip phone business_name contractor_ein].each do |col|
        attrs[col.to_sym] = data[col] if data[col].present?
      end

      # SSN → encrypted field
      if data["ssn"].present?
        attrs[:ssn_encrypted] = data["ssn"].gsub(/\D/, "")
      end

      # Employment type with defaults
      attrs[:employment_type] = data["employment_type"].presence || "hourly"
      attrs[:salary_type] = data["salary_type"].presence || "annual" if attrs[:employment_type] == "salary"
      attrs[:pay_frequency] = data["pay_frequency"].presence || company.pay_frequency
      attrs[:status] = "active"

      # Filing status defaults for W-2 employees
      unless attrs[:employment_type] == "contractor"
        attrs[:filing_status] = data["filing_status"].presence || "single"
      end

      # Contractor fields
      if attrs[:employment_type] == "contractor"
        attrs[:contractor_type] = data["contractor_type"].presence || "individual"
        attrs[:contractor_pay_type] = data["contractor_pay_type"].presence || "flat_fee"
      end

      # Integer fields (allowances)
      INTEGER_COLUMNS.each do |col|
        next if data[col].blank?
        attrs[col.to_sym] = Integer(data[col]) rescue 0
      end

      # Numeric fields
      NUMERIC_COLUMNS.each do |col|
        next if data[col].blank?
        attrs[col.to_sym] = BigDecimal(data[col]) rescue 0
      end

      # Boolean fields
      BOOLEAN_COLUMNS.each do |col|
        next if data[col].blank?
        attrs[col.to_sym] = %w[true yes 1 y].include?(data[col].downcase)
      end

      # Date fields
      DATE_COLUMNS.each do |col|
        next if data[col].blank?
        attrs[col.to_sym] = Date.parse(data[col]) rescue nil
      end

      # Department lookup by name
      if data["department"].present?
        dept_key = data["department"].downcase.strip
        dept = departments[dept_key]
        attrs[:department_id] = dept.id if dept
        attrs[:_department_name] = data["department"].strip
      end

      attrs
    end
  end
end
