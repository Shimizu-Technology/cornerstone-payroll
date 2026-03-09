# frozen_string_literal: true

module PayrollImport
  # Parses the MoSa Excel template containing tips and loans
  #
  # Sheet structure:
  #   TIPS - BOH: Row 4=headers, data from row 5. Col C=Last Name, Col D=First Name, Col F=Tip Amount
  #   TIPS - FOH: Row 4=headers, data from row 6. Col C=Last Name, Col D=First Name, Col F=Tip Amount
  #   LOANS (NO INSTALLMENTS): Same structure, Col F=Loan Amount
  #   INSTALLMENT LOANS: Col C=Last, Col D=First, Col H=Payment This Period
  #   SUMMARY: Skip (broken)
  #
  # Returns array of hashes:
  # - last_name (string)
  # - first_name (string)
  # - total_tips (decimal)
  # - tip_pool (string): "boh" or "foh"
  # - loan_deduction (decimal)
  class LoanTipExcelParser
    TIPS_BOH_SHEET = "TIPS - BOH"
    TIPS_FOH_SHEET = "TIPS - FOH"
    LOANS_SHEET = "LOANS (NO INSTALLMENTS)"
    INSTALLMENT_SHEET = "INSTALLMENT LOANS"
    SKIP_SHEETS = [ "SUMMARY" ].freeze

    class << self
      def parse(file_path)
        new(file_path).parse
      end

      def parse_file(file)
        return parse(file.path) if file.respond_to?(:path)

        tempfile = save_to_temp(file)
        begin
          parse(tempfile.path)
        ensure
          tempfile.unlink if tempfile
        end
      end

      private

      def save_to_temp(file)
        tempfile = Tempfile.new([ "upload", ".xlsx" ])
        tempfile.binmode
        tempfile.write(file.read)
        tempfile.close
        tempfile
      end
    end

    def initialize(file_path)
      @file_path = file_path
      validate_file!
    end

    def parse
      xlsx = Roo::Spreadsheet.open(file_path)
      employees = {}

      parse_tips_sheet(xlsx, TIPS_BOH_SHEET, "boh", employees)
      parse_tips_sheet(xlsx, TIPS_FOH_SHEET, "foh", employees)
      parse_loans_sheet(xlsx, employees)
      parse_installment_sheet(xlsx, employees)

      employees.values
    end

    private

    attr_reader :file_path

    def validate_file!
      raise ArgumentError, "File not found: #{file_path}" unless File.exist?(file_path)

      unless file_path.match?(/\.(xlsx?|xls)$/i)
        raise ArgumentError, "File is not an Excel file"
      end
    end

    def employee_key(last_name, first_name)
      "#{last_name&.strip&.downcase}|#{first_name&.strip&.downcase}"
    end

    def find_or_init(employees, last_name, first_name)
      key = employee_key(last_name, first_name)
      employees[key] ||= {
        last_name: last_name&.strip,
        first_name: first_name&.strip,
        total_tips: 0.0,
        tip_pool: nil,
        loan_deduction: 0.0
      }
    end

    def parse_tips_sheet(xlsx, sheet_name, pool, employees)
      return unless xlsx.sheets.include?(sheet_name)

      sheet = xlsx.sheet(sheet_name)
      # Data starts at row 5 for BOH, row 6 for FOH; scan from row 5 to be safe
      start_row = pool == "foh" ? 6 : 5

      (start_row..sheet.last_row).each do |row_num|
        last_name = sheet.cell(row_num, 3)   # Col C
        first_name = sheet.cell(row_num, 4)  # Col D
        tip_amount = sheet.cell(row_num, 6)  # Col F

        next if last_name.blank? && first_name.blank?

        amount = to_decimal(tip_amount)
        next if amount.zero?

        emp = find_or_init(employees, last_name, first_name)
        emp[:total_tips] += amount
        emp[:tip_pool] = pool
      end
    end

    def parse_loans_sheet(xlsx, employees)
      return unless xlsx.sheets.include?(LOANS_SHEET)

      sheet = xlsx.sheet(LOANS_SHEET)

      (5..sheet.last_row).each do |row_num|
        last_name = sheet.cell(row_num, 3)   # Col C
        first_name = sheet.cell(row_num, 4)  # Col D
        loan_amount = sheet.cell(row_num, 6) # Col F

        next if last_name.blank? && first_name.blank?

        amount = to_decimal(loan_amount)
        next if amount.zero?

        emp = find_or_init(employees, last_name, first_name)
        emp[:loan_deduction] += amount
      end
    end

    def parse_installment_sheet(xlsx, employees)
      return unless xlsx.sheets.include?(INSTALLMENT_SHEET)

      sheet = xlsx.sheet(INSTALLMENT_SHEET)

      (5..sheet.last_row).each do |row_num|
        last_name = sheet.cell(row_num, 3)    # Col C
        first_name = sheet.cell(row_num, 4)   # Col D
        payment = sheet.cell(row_num, 8)      # Col H = Payment This Period

        next if last_name.blank? && first_name.blank?

        amount = to_decimal(payment)
        next if amount.zero?

        emp = find_or_init(employees, last_name, first_name)
        emp[:loan_deduction] += amount
      end
    end

    def to_decimal(value)
      case value
      when Numeric
        value.to_f.round(2)
      when String
        clean = value.gsub(/[$,]/, "")
        Float(clean).round(2)
      else
        0.0
      end
    rescue ArgumentError, TypeError
      0.0
    end
  end
end
