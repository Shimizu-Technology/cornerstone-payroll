# frozen_string_literal: true

require "fileutils"
require "spreadsheet"

module DemoCompany
  # Writes a fictional QuickBooks export bundle (the five reports the history
  # importer reads) for Harbor Finch Kitchen's June and July 2026 paydays,
  # before its first native payroll, plus a text PDF of the matching pay
  # stubs for the stub upload and match flow. An operator uploads both through
  # the normal import and stub review screens. Nothing here writes to the
  # database or sends anything.
  class QuickbooksSample
    COMPANY_NAME = "Harbor Finch Kitchen"
    # name, SSN (900 area, never issued), hourly rate, pay method, per payday:
    # [pay date, period, hours, gross, fit, ss, med, net, check number or nil]
    WORKERS = [
      { name: "Lantern, Robin", ssn: "900-01-1001", rate: 17.50, method: "Direct deposit", dob: "03/14/1994",
        paychecks: [ [ "06/19/2026", "06/01/2026 - 06/14/2026", 80, 1_400.00, 96.40, 86.80, 20.30, 1_196.50, nil ],
                     [ "07/03/2026", "06/15/2026 - 06/28/2026", 80, 1_400.00, 96.40, 86.80, 20.30, 1_196.50, nil ] ] },
      { name: "Drift, Rowan", ssn: "900-01-1003", rate: 9.25, method: "Check", dob: "11/02/1998",
        paychecks: [ [ "06/19/2026", "06/01/2026 - 06/14/2026", 72, 666.00, 10.40, 41.29, 9.66, 604.65, "901" ],
                     [ "07/03/2026", "06/15/2026 - 06/28/2026", 72, 666.00, 10.40, 41.29, 9.66, 604.65, "902" ] ] },
      { name: "Flint, Drew", ssn: "900-01-1010", rate: 15.00, method: "Direct deposit", dob: "07/21/1991",
        paychecks: [ [ "06/19/2026", "06/01/2026 - 06/14/2026", 80, 1_200.00, 72.40, 74.40, 17.40, 1_035.80, nil ],
                     [ "07/03/2026", "06/15/2026 - 06/28/2026", 80, 1_200.00, 72.40, 74.40, 17.40, 1_035.80, nil ] ] }
    ].freeze

    Result = Data.define(:files, :stub_pdf)

    def initialize(output_dir:)
      @output_dir = output_dir.to_s
    end

    def call
      FileUtils.mkdir_p(@output_dir)
      files = {
        "Payroll Details.xls" => details_rows,
        "Paycheck History.xls" => history_rows,
        "Employee Details.xls" => employee_details_rows,
        "Employee Directory.xls" => directory_rows,
        "Payroll Summary.xls" => summary_rows
      }.map { |name, rows| write_xls(name, rows) }
      Result.new(files: files, stub_pdf: write_stub_pdf)
    end

    def self.stub_pages
      WORKERS.flat_map do |worker|
        worker[:paychecks].map do |pay_date, period, hours, gross, fit, ss, med, net, check|
          { name: worker[:name].split(", ").reverse.join(" "), pay_date: pay_date, period: period, hours: hours,
            gross: gross, fit: fit, ss: ss, med: med, net: net, check: check }
        end
      end
    end

    private

    def title(report, range)
      [ [ COMPANY_NAME ], [ report ], [], [ range ] ]
    end

    def details_rows
      headers = [ "Name", "Pay date", "Time period", "Hours - total", "Hours - Regular", "Gross pay - total", "Gross pay - Regular",
        "Adjusted gross", "Employee taxes - total", "Employee taxes - FIT", "Employee taxes - SS", "Employee taxes - Med",
        "Net pay", "Employer taxes - total", "Employer taxes - SS", "Employer taxes - Med", "Total payroll cost" ]
      rows = WORKERS.flat_map do |worker|
        worker[:paychecks].map do |pay_date, period, hours, gross, fit, ss, med, net, _check|
          taxes = -(fit + ss + med).round(2)
          [ worker[:name], pay_date, period, hours, hours, gross, gross, gross, taxes, -fit, -ss, -med, net,
            (ss + med).round(2), ss, med, (gross + ss + med).round(2) ]
        end
      end
      totals = [ "Total", nil, nil, rows.sum { |row| row[3] }, rows.sum { |row| row[4] }, rows.sum { |row| row[5] }.round(2) ]
      title("Payroll details report", "From Jun 01, 2026 to Jul 31, 2026") + [ headers, *rows, totals ]
    end

    def history_rows
      rows = WORKERS.flat_map do |worker|
        worker[:paychecks].map do |pay_date, _period, _hours, gross, *_taxes, net, check|
          [ pay_date, worker[:name], gross, net, check ? "Check" : "Direct deposit", check || "-", "-" ]
        end
      end
      title("Paycheck history report", "Paychecks from Jun 01, 2026 to Jul 31, 2026") +
        [ [ "Pay date", "Name", "Total pay", "Net pay", "Pay method", "Check Number", "Status" ], *rows ]
    end

    def employee_details_rows
      rows = WORKERS.map do |worker|
        [ "#{worker[:name]} DOB: #{worker[:dob]}", "05/18/2026", "Hagåtña kitchen",
          format("Hourly rate: $%.2f/hr Pay method: %s Deductions: None Contributions: None Time off: None", worker[:rate], worker[:method]),
          "SSN: #{worker[:ssn]} Fed: Single or Married Filing Separately", "" ]
      end
      title("Employee details report", "For all employees") +
        [ [ "Personal info", "Hire date", "Work location", "Pay info", "Tax info", "Notes" ], *rows ]
    end

    def directory_rows
      rows = WORKERS.map { |worker| [ worker[:name], worker[:dob], "", "", "", "", "", "Hagåtña kitchen", "05/18/2026" ] }
      title("Employee directory report", "For all employees from all locations") +
        [ [ "Name", "Birth date", "Email", "Work phone", "Home phone", "Mobile", "Home address", "Work location", "Hire date" ], *rows ]
    end

    def summary_rows
      rows = WORKERS.flat_map do |worker|
        worker[:paychecks].map do |pay_date, _period, hours, gross, fit, ss, med, net, check|
          [ pay_date, worker[:name], hours, gross, 0, 0, -(fit + ss + med).round(2), 0, net, (ss + med).round(2), 0,
            (gross + ss + med).round(2), check ? "Check" : "Direct deposit" ]
        end
      end
      title("Payroll summary report", "From Jun 01, 2026 to Jul 31, 2026 for all employees from all locations") +
        [ [ "Pay date", "Name", "Hours", "Gross pay", "Pretax deductions", "Other pay", "Employee taxes", "Aftertax deduction",
            "Net pay", "Employer taxes", "Company contributions", "Total payroll cost", "Pay method" ], *rows ]
    end

    def write_xls(name, rows)
      path = File.join(@output_dir, name)
      workbook = Spreadsheet::Workbook.new
      sheet = workbook.create_worksheet
      rows.each_with_index { |row, row_index| row.each_with_index { |value, column| sheet[row_index, column] = value } }
      workbook.write(path)
      path
    end

    # One page per pay stub, with the labeled lines the stub matcher reads.
    # Text only: no signature, MICR line, bank number or full SSN.
    def write_stub_pdf
      path = File.join(@output_dir, "Harbor Finch Kitchen pay stubs Jun-Jul 2026.pdf")
      document = PdfUnicodeFont.document
      self.class.stub_pages.each_with_index do |page, index|
        document.start_new_page if index.positive?
        document.text COMPANY_NAME, size: 16, style: :bold
        document.text "214 Marine Corps Drive, Hagåtña, GU 96910"
        document.move_down 12
        document.text "Employee: #{page[:name]}"
        document.text "Pay period: #{page[:period]}"
        document.text "Check date: #{page[:pay_date]}"
        document.text(page[:check] ? "Check no. #{page[:check]}" : "Paid by direct deposit")
        document.move_down 8
        document.text format("Hours: %.2f", page[:hours])
        document.text format("Gross pay: $%.2f", page[:gross])
        document.text format("Federal income tax: $%.2f", page[:fit])
        document.text format("Social Security: $%.2f", page[:ss])
        document.text format("Medicare: $%.2f", page[:med])
        document.text format("Net pay: $%.2f", page[:net])
      end
      document.render_file(path)
      path
    end
  end
end
