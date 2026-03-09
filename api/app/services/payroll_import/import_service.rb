# frozen_string_literal: true

module PayrollImport
  # Orchestrates the payroll import process:
  # 1. Parse Revel PDF (hours + gross pay)
  # 2. Parse Excel template (tips + loans)
  # 3. Match names to Employee records
  # 4. Return preview data
  # 5. Apply import to create/update PayrollItems
  class ImportService
    attr_reader :pay_period, :company_id

    def initialize(pay_period)
      @pay_period = pay_period
      @company_id = pay_period.company_id
    end

    # Preview: parse files and match names without persisting
    # @param pdf_file [File, nil] Revel POS PDF
    # @param excel_file [File, nil] Tips/Loans Excel
    # @return [Hash] preview data with matched employees
    def preview(pdf_file:, excel_file: nil)
      employees = Employee.active.where(company_id: company_id)
      matcher = NameMatcher.new(employees)

      pdf_records = pdf_file ? RevelPdfParser.parse_file(pdf_file) : []
      excel_records = excel_file ? LoanTipExcelParser.parse_file(excel_file) : []

      matched = []
      unmatched = []

      pdf_records.each do |pdf_row|
        match = matcher.match_pdf_name(pdf_row[:employee_name])

        if match
          employee = employees.find { |e| e.id == match[:employee_id] }
          excel_data = find_excel_data(excel_records, employee)

          matched << build_preview_row(pdf_row, employee, match, excel_data)
        else
          unmatched << pdf_row[:employee_name]
        end
      end

      # Handle Excel-only employees (have tips/loans but no PDF hours)
      excel_records.each do |excel_row|
        excel_match = matcher.match_excel_name(excel_row[:last_name], excel_row[:first_name])
        next unless excel_match
        next if matched.any? { |m| m[:employee_id] == excel_match[:employee_id] }

        employee = employees.find { |e| e.id == excel_match[:employee_id] }
        matched << build_preview_row(nil, employee, excel_match, excel_row)
      end

      {
        matched: matched,
        unmatched_pdf_names: unmatched,
        pdf_count: pdf_records.length,
        excel_count: excel_records.length,
        matched_count: matched.length
      }
    end

    # Apply: persist matched import data to PayrollItems
    # @param preview_data [Hash] from preview method or from controller params
    # @return [Hash] results with success/error counts
    def apply!(preview_data)
      results = { success: [], errors: [] }

      ActiveRecord::Base.transaction do
        preview_data[:matched].each do |row|
          employee_id = row[:employee_id]
          employee = Employee.find_by(id: employee_id, company_id: company_id)
          next unless employee

          begin
            payroll_item = pay_period.payroll_items.find_or_initialize_by(employee_id: employee.id)

            # Set employment info
            payroll_item.employment_type = employee.employment_type

            # Derive pay rate from PDF: regular_pay / regular_hours (most accurate)
            # Fall back to employee.pay_rate if PDF data is insufficient
            pdf_rate = if row[:regular_hours].to_f > 0 && row[:regular_pay].to_f > 0
              (row[:regular_pay].to_f / row[:regular_hours].to_f).round(4)
            elsif row[:total_hours].to_f > 0 && row[:total_pay].to_f > 0
              (row[:total_pay].to_f / row[:total_hours].to_f).round(4)
            end

            payroll_item.pay_rate = pdf_rate || employee.pay_rate

            # Update employee's stored pay rate if we derived a better one
            if pdf_rate && (pdf_rate - employee.pay_rate.to_f).abs > 0.01
              employee.update_column(:pay_rate, pdf_rate)
            end

            # Set hours from PDF
            payroll_item.hours_worked = row[:regular_hours].to_f if row[:regular_hours]
            payroll_item.overtime_hours = row[:overtime_hours].to_f if row[:overtime_hours]

            # Set tips from Excel — store in reported_tips only
            # (HourlyPayrollCalculator sums reported_tips + tips, so we only set one)
            payroll_item.reported_tips = row[:total_tips].to_f
            payroll_item.tips = 0.0  # Reset to avoid double-counting
            payroll_item.tip_pool = row[:tip_pool] if row[:tip_pool]
            payroll_item.loan_deduction = row[:loan_deduction].to_f if row[:loan_deduction]
            payroll_item.import_source = "mosa_revel"

            # Calculate payroll (taxes, deductions, net pay)
            payroll_item.calculate!

            results[:success] << { employee_id: employee.id, name: employee.full_name }
          rescue StandardError => e
            results[:errors] << { employee_id: employee.id, name: employee&.full_name, error: e.message }
          end
        end

        # Update pay period status
        pay_period.update!(status: "calculated") if results[:errors].empty? && results[:success].any?
      end

      results
    end

    private

    def find_excel_data(excel_records, employee)
      return nil if excel_records.empty?

      excel_records.find do |row|
        row[:last_name]&.strip&.downcase == employee.last_name.downcase &&
          row[:first_name]&.strip&.downcase == employee.first_name.downcase
      end
    end

    def build_preview_row(pdf_row, employee, match, excel_data)
      row = {
        employee_id: employee.id,
        employee_name: employee.full_name,
        employment_type: employee.employment_type,
        pay_rate: employee.pay_rate.to_f,
        confidence: match[:confidence],
        matched_name: match[:matched_name],
        # PDF data
        regular_hours: pdf_row&.dig(:regular_hours) || 0.0,
        overtime_hours: pdf_row&.dig(:overtime_hours) || 0.0,
        regular_pay: pdf_row&.dig(:regular_pay) || 0.0,
        overtime_pay: pdf_row&.dig(:overtime_pay) || 0.0,
        total_hours: pdf_row&.dig(:total_hours) || 0.0,
        total_pay: pdf_row&.dig(:total_pay) || 0.0,
        pdf_employee_name: pdf_row&.dig(:employee_name),
        # Excel data
        total_tips: excel_data&.dig(:total_tips) || 0.0,
        tip_pool: excel_data&.dig(:tip_pool),
        loan_deduction: excel_data&.dig(:loan_deduction) || 0.0
      }

      row
    end
  end
end
