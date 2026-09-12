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
    BONUS_SHEET = "BONUSES"
    SKIP_SHEETS = [ "SUMMARY" ].freeze

    class << self
      def parse(file_path)
        new(file_path).parse
      end

      def parse_with_metadata(file_path)
        new(file_path).parse_with_metadata
      end

      def parse_file(file)
        parse_file_with_metadata(file).fetch(:rows)
      end

      def parse_file_with_metadata(file)
        return parse_with_metadata(file.path) if file.respond_to?(:path)

        tempfile = save_to_temp(file)
        begin
          parse_with_metadata(tempfile.path)
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
      parse_with_metadata.fetch(:rows)
    end

    def parse_with_metadata
      xlsx = Roo::Spreadsheet.open(file_path)
      employees = {}

      if generated_template?(xlsx)
        parse_generated_employee_changes(xlsx, employees)
        parse_generated_deductions_and_loans(xlsx, employees)
        reject_generated_hour_corrections!(xlsx)
      else
        parse_tips_sheet(xlsx, TIPS_BOH_SHEET, "boh", employees)
        parse_tips_sheet(xlsx, TIPS_FOH_SHEET, "foh", employees)
        parse_loans_sheet(xlsx, employees)
        parse_installment_sheet(xlsx, employees)
        parse_bonus_sheet(xlsx, employees)
      end

      metadata = workbook_metadata(xlsx)
      if metadata[:no_changes] && employees.any?
        raise ArgumentError, "The workbook says there are no supplemental changes but also contains changed rows."
      end

      { rows: employees.values, metadata: metadata }
    end

    private

    attr_reader :file_path

    def validate_file!
      raise ArgumentError, "File not found: #{file_path}" unless File.exist?(file_path)

      unless file_path.match?(/\.(xlsx?|xls)$/i)
        raise ArgumentError, "File is not an Excel file"
      end
    end

    def employee_key(last_name, first_name, employee_id = nil)
      return "id:#{employee_id}" if employee_id.present?

      "name:#{last_name&.strip&.downcase}|#{first_name&.strip&.downcase}"
    end

    def find_or_init(employees, last_name, first_name, employee_id: nil, employee_name: nil)
      key = employee_key(last_name, first_name, employee_id)
      employees[key] ||= {
        employee_id: employee_id&.to_i,
        employee_name: employee_name.to_s.strip.presence,
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

    def generated_template?(xlsx)
      return false unless xlsx.sheets.include?("START HERE")

      workbook_metadata(xlsx)[:schema_version] == PayrollImport::MosaSupplementalTemplate::SCHEMA_VERSION
    end

    def workbook_metadata(xlsx)
      if xlsx.sheets.include?("START HERE")
        sheet = xlsx.sheet("START HERE")
        values = (1..sheet.last_row).each_with_object({}) do |row, result|
          label = sheet.cell(row, 1).to_s.strip.downcase
          result[label] = sheet.cell(row, 2) if label.present?
        end
        {
          schema_version: values["schema version"].to_s.strip.presence,
          company_id: integer(values["company id"]),
          period_start: date(values["pay period start"]),
          period_end: date(values["pay period end"]),
          pay_date: date(values["pay date"]),
          template_revision: integer(values["template revision"]),
          prior_revision_replaced: values["prior revision replaced"].to_s.strip.presence,
          submitter: values["submitter"].to_s.strip.presence,
          submitted_at: values["submitted at"].to_s.strip.presence,
          revel_filename: values["revel filename"].to_s.strip.presence,
          no_changes: yes?(values["no supplemental changes? (yes/no)"]),
          attestation: values["attestation"].to_s.strip.presence
        }
      else
        legacy_metadata(xlsx)
      end
    end

    def legacy_metadata(xlsx)
      candidate = [ TIPS_BOH_SHEET, TIPS_FOH_SHEET, LOANS_SHEET, INSTALLMENT_SHEET, BONUS_SHEET ]
        .find { |sheet_name| xlsx.sheets.include?(sheet_name) }
      return {} unless candidate

      sheet = xlsx.sheet(candidate)
      {
        schema_version: "mosa-legacy-workbook",
        period_end: date(sheet.cell(2, 6)),
        pay_date: date(sheet.cell(3, 6)),
        no_changes: false
      }
    end

    def parse_generated_employee_changes(xlsx, employees)
      sheet = xlsx.sheet(PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET)
      each_data_row(sheet, 2) do |row_num|
        employee_id = integer(sheet.cell(row_num, 1))
        employee_name = sheet.cell(row_num, 2).to_s.strip
        values = (4..12).map { |column| sheet.cell(row_num, column) }
        next if values.all?(&:blank?)
        raise ArgumentError, "EMPLOYEE CHANGES row #{row_num}: Employee ID is required." unless employee_id

        names = employee_name.split
        employee = find_or_init(
          employees,
          names.last,
          names[0...-1].join(" "),
          employee_id: employee_id,
          employee_name: employee_name
        )
        employee[:tips_boh] += to_decimal(sheet.cell(row_num, 4))
        employee[:tips_foh] += to_decimal(sheet.cell(row_num, 5))
        employee[:total_tips] = employee[:tips_boh] + employee[:tips_foh]
        employee[:tip_pool] = tip_pool(employee)
        employee[:tips_already_paid] = yes_no(sheet.cell(row_num, 6), row_num: row_num)
        bonus = sheet.cell(row_num, 7)
        employee[:bonus] = PayrollBonusInput.amount(bonus.to_s.delete("$,")) unless bonus.blank?
        deduction = to_decimal(sheet.cell(row_num, 8))
        employee[:recurring_loan_deduction] += deduction
        employee[:loan_deduction] += deduction
        employee[:effective_date] = date(sheet.cell(row_num, 9))
        employee[:recipient] = sheet.cell(row_num, 10).to_s.strip.presence
        employee[:source] = sheet.cell(row_num, 11).to_s.strip.presence
        employee[:notes] = sheet.cell(row_num, 12).to_s.strip.presence
      rescue ArgumentError => e
        raise ArgumentError, "EMPLOYEE CHANGES row #{row_num}: #{e.message}" unless e.message.start_with?("EMPLOYEE CHANGES row")

        raise
      end
    end

    def parse_generated_deductions_and_loans(xlsx, employees)
      sheet = xlsx.sheet(PayrollImport::MosaSupplementalTemplate::DEDUCTIONS_LOANS_SHEET)
      each_data_row(sheet, 2) do |row_num|
        action = sheet.cell(row_num, 7).to_s.strip.upcase
        amount = to_decimal(sheet.cell(row_num, 8))
        opening = to_decimal(sheet.cell(row_num, 11))
        addition = to_decimal(sheet.cell(row_num, 12))
        payment = to_decimal(sheet.cell(row_num, 13))
        ending = to_decimal(sheet.cell(row_num, 14))
        next if action.blank? && [ amount, addition, payment ].all?(&:zero?)
        next if action == "KEEP" && [ amount, addition, payment ].all?(&:zero?)

        employee_id = integer(sheet.cell(row_num, 1))
        raise ArgumentError, "DEDUCTIONS & LOANS row #{row_num}: Employee ID is required." unless employee_id
        raise ArgumentError, "DEDUCTIONS & LOANS row #{row_num}: Action must be KEEP, CHANGE, or STOP." unless action.in?(%w[KEEP CHANGE STOP])
        if ending.positive? && (opening + addition - payment - ending).abs > 0.01
          raise ArgumentError, "DEDUCTIONS & LOANS row #{row_num}: Opening balance + new advance - payment must equal ending balance."
        end
        unless action == "KEEP" && addition.zero?
          raise ArgumentError,
                "DEDUCTIONS & LOANS row #{row_num}: recurring setup changes and new loan advances must be made and reviewed in Cornerstone before this payroll is imported."
        end

        employee_name = sheet.cell(row_num, 2).to_s.strip
        names = employee_name.split
        employee = find_or_init(
          employees,
          names.last,
          names[0...-1].join(" "),
          employee_id: employee_id,
          employee_name: employee_name
        )
        employee[:recurring_loan_deduction] += amount
        employee[:installment_beginning_balance] = [ employee[:installment_beginning_balance], opening ].max
        employee[:installment_new_amount] += addition
        employee[:installment_payment] += payment
        employee[:installment_estimated_ending_balance] = [ employee[:installment_estimated_ending_balance], ending ].max
        employee[:loan_deduction] += amount + payment
        employee[:loan_action] = action
        employee[:component_reference] = sheet.cell(row_num, 3).to_s.strip.presence
        employee[:effective_date] ||= date(sheet.cell(row_num, 9))
        employee[:recipient] ||= sheet.cell(row_num, 15).to_s.strip.presence
        employee[:source] ||= sheet.cell(row_num, 16).to_s.strip.presence
      end
    end

    def reject_generated_hour_corrections!(xlsx)
      return unless xlsx.sheets.include?(PayrollImport::MosaSupplementalTemplate::HOUR_CORRECTIONS_SHEET)

      sheet = xlsx.sheet(PayrollImport::MosaSupplementalTemplate::HOUR_CORRECTIONS_SHEET)
      each_data_row(sheet, 2) do |row_num|
        next if (1..10).all? { |column| sheet.cell(row_num, column).blank? }

        raise ArgumentError,
              "HOUR CORRECTIONS row #{row_num}: review hour corrections in Cornerstone before importing; this workbook cannot silently change Revel hours."
      end
    end

    def tip_pool(employee)
      return "mixed" if employee[:tips_boh].positive? && employee[:tips_foh].positive?
      return "boh" if employee[:tips_boh].positive?
      return "foh" if employee[:tips_foh].positive?

      nil
    end

    def yes_no(value, row_num:)
      normalized = value.to_s.strip.upcase
      return nil if normalized.blank?
      return true if normalized == "YES"
      return false if normalized == "NO"

      raise ArgumentError, "Tips already paid must be YES or NO (row #{row_num})."
    end

    def yes?(value)
      value.to_s.strip.casecmp("YES").zero?
    end

    def integer(value)
      return nil if value.blank?

      Integer(Float(value))
    rescue ArgumentError, TypeError
      nil
    end

    def date(value)
      return value.to_date if value.respond_to?(:to_date)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue Date::Error
      nil
    end

    def parse_tips_sheet(xlsx, sheet_name, pool, employees)
      return unless xlsx.sheets.include?(sheet_name)

      sheet = xlsx.sheet(sheet_name)
      # Row 4 is the header row in both BOH and FOH; data starts at row 5.
      start_row = 5

      each_data_row(sheet, start_row) do |row_num|
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

      each_data_row(sheet, 5) do |row_num|
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

      each_data_row(sheet, 5) do |row_num|
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

    # Optional explicit bonus sheet: row 4 headers, C last name, D first name,
    # F one-time bonus. Blank is absent; zero explicitly clears an imported bonus.
    def parse_bonus_sheet(xlsx, employees)
      return unless xlsx.sheets.include?(BONUS_SHEET)

      sheet = xlsx.sheet(BONUS_SHEET)
      each_data_row(sheet, 5) do |row_num|
        last_name = sheet.cell(row_num, 3)
        first_name = sheet.cell(row_num, 4)
        value = sheet.cell(row_num, 6)
        next if last_name.blank? || value.blank?

        employee = find_or_init(employees, last_name, first_name)
        raise ArgumentError, "Duplicate bonus row for #{first_name} #{last_name}." if employee.key?(:bonus)

        employee[:bonus] = PayrollBonusInput.amount(value.to_s.delete("$,"))
      rescue ArgumentError => e
        raise ArgumentError, "BONUSES row #{row_num}: #{e.message}"
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

    def each_data_row(sheet, start_row)
      last_row = sheet.last_row.to_i
      return if last_row < start_row

      (start_row..last_row).each { |row_num| yield row_num }
    end
  end
end
