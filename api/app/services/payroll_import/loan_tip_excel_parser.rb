# frozen_string_literal: true

module PayrollImport
  # Parses the MoSa Excel template containing tips and loans
  #
  # Sheet structure:
  #   TIPS - BOH: Row 4=headers, data from row 5. Col C=Last Name, Col D=First Name, Col F=Tip Amount
  #   TIPS - FOH: Row 4=headers, data from row 5. Col C=Last Name, Col D=First Name, Col F=Tip Amount
  #   LOANS (NO INSTALLMENTS): Same structure, Col F=Loan Amount
  #   INSTALLMENT LOANS: Col C=Last, Col D=First, Col F=Beginning Balance,
  #     Col G=New Loan Amount, Col H=Payment This Period, Col I=Estimated Ending Balance
  #   SUMMARY: Skip (broken)
  #
  # Returns array of hashes:
  # - last_name (string)
  # - first_name (string)
  # - total_tips (decimal)
  # - tips_boh (decimal)
  # - tips_foh (decimal)
  # - tip_pool (string): "boh", "foh", or "mixed"
  # - loan_deduction (decimal): one-payroll deduction + installment payment
  # - recurring_loan_deduction (decimal): legacy key for the one-payroll
  #   LOANS (NO INSTALLMENTS) amount; this does not create a recurring setup
  # - installment_beginning_balance (decimal)
  # - installment_new_amount (decimal)
  # - installment_payment (decimal)
  # - installment_estimated_ending_balance (decimal)
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
        tips_boh: 0.0,
        tips_foh: 0.0,
        tip_pool: nil,
        loan_deduction: 0.0,
        recurring_loan_deduction: 0.0,
        installment_beginning_balance: 0.0,
        installment_new_amount: 0.0,
        installment_payment: 0.0,
        installment_estimated_ending_balance: 0.0
      }
    end

    def parse_tips_sheet(xlsx, sheet_name, pool, employees)
      return unless xlsx.sheets.include?(sheet_name)

      sheet = xlsx.sheet(sheet_name)
      # Row 4 is the header row in both BOH and FOH; data starts at row 5.
      start_row = 5

      (start_row..sheet.last_row).each do |row_num|
        last_name = sheet.cell(row_num, 3)   # Col C
        first_name = sheet.cell(row_num, 4)  # Col D
        tip_amount = sheet.cell(row_num, 6)  # Col F

        next if last_name.blank?

        amount = to_decimal(tip_amount)
        next if amount.zero?

        emp = find_or_init(employees, last_name, first_name)
        emp[:total_tips] += amount
        emp[pool == "boh" ? :tips_boh : :tips_foh] += amount

        # Preserve dual-pool visibility when an employee appears in both BOH and FOH sheets.
        if emp[:tip_pool].nil?
          emp[:tip_pool] = pool
        elsif emp[:tip_pool] != pool
          emp[:tip_pool] = "mixed"
        end
      end
    end

    def parse_loans_sheet(xlsx, employees)
      return unless xlsx.sheets.include?(LOANS_SHEET)

      sheet = xlsx.sheet(LOANS_SHEET)

      (5..sheet.last_row).each do |row_num|
        last_name = sheet.cell(row_num, 3)   # Col C
        first_name = sheet.cell(row_num, 4)  # Col D
        loan_amount = sheet.cell(row_num, 6) # Col F

        next if last_name.blank?

        amount = to_decimal(loan_amount)
        next if amount.zero?

        emp = find_or_init(employees, last_name, first_name)
        emp[:recurring_loan_deduction] += amount
        emp[:loan_deduction] += amount
      end
    end

    def parse_installment_sheet(xlsx, employees)
      return unless xlsx.sheets.include?(INSTALLMENT_SHEET)

      sheet = xlsx.sheet(INSTALLMENT_SHEET)

      (5..sheet.last_row).each do |row_num|
        last_name = sheet.cell(row_num, 3)          # Col C
        first_name = sheet.cell(row_num, 4)         # Col D
        beginning_balance = sheet.cell(row_num, 6)  # Col F
        new_amount = sheet.cell(row_num, 7)         # Col G
        payment = sheet.cell(row_num, 8)            # Col H = Payment This Period
        estimated_ending = sheet.cell(row_num, 9)   # Col I

        next if last_name.blank?

        beginning_balance_amount = to_decimal(beginning_balance)
        new_amount_value = to_decimal(new_amount)
        payment_amount = to_decimal(payment)
        estimated_ending_amount = to_decimal(estimated_ending)
        next if [ beginning_balance_amount, new_amount_value, payment_amount, estimated_ending_amount ].all?(&:zero?)

        emp = find_or_init(employees, last_name, first_name)
        emp[:installment_beginning_balance] = [ emp[:installment_beginning_balance], beginning_balance_amount ].max
        emp[:installment_new_amount] += new_amount_value
        emp[:installment_payment] += payment_amount
        emp[:installment_estimated_ending_balance] = [ emp[:installment_estimated_ending_balance], estimated_ending_amount ].max
        emp[:loan_deduction] += payment_amount
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
