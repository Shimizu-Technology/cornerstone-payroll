# frozen_string_literal: true

require "fileutils"
require "spreadsheet"

module DemoCompany
  # Writes Harbor Finch Kitchen's fictional QuickBooks history for January
  # through July 2026: the five reports the history importer reads, Tax and
  # Wage Summaries for Q1, Q2 and January–July, and a text PDF with one pay
  # stub per paycheck for the stub upload and match flow. Every figure comes
  # from Roster.quickbooks_paycheck, so the reports, stubs and later YTD agree.
  # It writes files only.
  class QuickbooksSample
    COMPANY_NAME = "Harbor Finch Kitchen"
    FIRST_CHECK_NUMBER = 501
    Result = Data.define(:files, :stub_pdfs)

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
        "Payroll Summary.xls" => summary_rows,
        "Tax_and_Wage_Summary_2026_Q1.xls" => tax_wage_rows(Date.new(2026, 1, 1), Date.new(2026, 3, 31)),
        "Tax_and_Wage_Summary_2026_Q2.xls" => tax_wage_rows(Date.new(2026, 4, 1), Date.new(2026, 6, 30)),
        "Tax_and_Wage_Summary_2026_YTD.xls" => tax_wage_rows(Date.new(2026, 1, 1), Date.new(2026, 7, 31))
      }.map { |name, rows| write_xls(name, rows) }
      Result.new(files: files, stub_pdfs: write_stub_pdfs)
    end

    # Every paycheck, in pay-date order, with its check number (paper checks
    # only) and the QuickBooks "Last, First" name.
    def self.paychecks
      number = FIRST_CHECK_NUMBER - 1
      Roster.quickbooks_periods.flat_map do |period|
        Roster.quickbooks_people.map do |person|
          paycheck = Roster.quickbooks_paycheck(person, period)
          check = person[:delivery] == "paper_check" ? (number += 1).to_s : nil
          paycheck.merge(person: person, name: "#{person[:last]}, #{person[:first]}", check: check)
        end
      end
    end

    private

    def mdy(date) = date.strftime("%m/%d/%Y")

    def long(date) = date.strftime("%b %d, %Y")

    def title(report, range) = [ [ COMPANY_NAME ], [ report ], [], [ range ] ]

    def employer(paycheck) = (paycheck[:ss] + paycheck[:med]).round(2)

    def details_rows
      headers = [ "Name", "Pay date", "Time period", "Hours - total", "Hours - Regular", "Gross pay - total", "Gross pay - Regular",
        "Adjusted gross", "Employee taxes - total", "Employee taxes - FIT", "Employee taxes - SS", "Employee taxes - Med",
        "Net pay", "Employer taxes - total", "Employer taxes - SS", "Employer taxes - Med", "Total payroll cost" ]
      rows = self.class.paychecks.map do |p|
        [ p[:name], mdy(p[:pay_date]), "#{mdy(p[:start_date])} - #{mdy(p[:end_date])}", p[:hours], p[:hours], p[:gross], p[:gross],
          p[:gross], -(p[:fit] + p[:ss] + p[:med]).round(2), -p[:fit], -p[:ss], -p[:med], p[:net], employer(p), p[:ss], p[:med],
          (p[:gross] + employer(p)).round(2) ]
      end
      total = [ "Total", nil, nil, rows.sum { |row| row[3] }, rows.sum { |row| row[4] }, rows.sum { |row| row[5] }.round(2) ]
      title("Payroll details report", "From Jan 01, 2026 to Jul 31, 2026") + [ headers, *rows, total ]
    end

    def history_rows
      rows = self.class.paychecks.map do |p|
        [ mdy(p[:pay_date]), p[:name], p[:gross], p[:net], p[:check] ? "Check" : "Direct deposit", p[:check] || "-", "-" ]
      end
      title("Paycheck history report", "Paychecks from Jan 01, 2026 to Jul 31, 2026") +
        [ [ "Pay date", "Name", "Total pay", "Net pay", "Pay method", "Check Number", "Status" ], *rows ]
    end

    def employee_details_rows
      rows = Roster.quickbooks_people.map do |person|
        method = person[:delivery] == "paper_check" ? "Check" : "Direct deposit"
        [ "#{person[:last]}, #{person[:first]} DOB: #{mdy(person[:dob])}", mdy(person[:hire_date]), "Hagåtña kitchen",
          format("Hourly rate: $%.2f/hr Pay method: %s Deductions: None Contributions: None Time off: None", person[:rate], method),
          "SSN: #{person[:ssn]} Fed: Single or Married Filing Separately", "" ]
      end
      title("Employee details report", "For all employees") +
        [ [ "Personal info", "Hire date", "Work location", "Pay info", "Tax info", "Notes" ], *rows ]
    end

    def directory_rows
      rows = Roster.quickbooks_people.map do |person|
        [ "#{person[:last]}, #{person[:first]}", mdy(person[:dob]), "", "", "", person[:phone], "", "Hagåtña kitchen", mdy(person[:hire_date]) ]
      end
      title("Employee directory report", "For all employees from all locations") +
        [ [ "Name", "Birth date", "Email", "Work phone", "Home phone", "Mobile", "Home address", "Work location", "Hire date" ], *rows ]
    end

    def summary_rows
      rows = self.class.paychecks.map do |p|
        [ mdy(p[:pay_date]), p[:name], p[:hours], p[:gross], 0, 0, -(p[:fit] + p[:ss] + p[:med]).round(2), 0, p[:net], employer(p), 0,
          (p[:gross] + employer(p)).round(2), p[:check] ? "Check" : "Direct deposit" ]
      end
      title("Payroll summary report", "From Jan 01, 2026 to Jul 31, 2026 for all employees from all locations") +
        [ [ "Pay date", "Name", "Hours", "Gross pay", "Pretax deductions", "Other pay", "Employee taxes", "Aftertax deduction",
            "Net pay", "Employer taxes", "Company contributions", "Total payroll cost", "Pay method" ], *rows ]
    end

    def tax_wage_rows(from, to)
      checks = self.class.paychecks.select { |p| p[:pay_date].between?(from, to) }
      wages = checks.sum { |p| p[:gross] }.round(2)
      fit = checks.sum { |p| p[:fit] }.round(2)
      ss = checks.sum { |p| p[:ss] }.round(2)
      med = checks.sum { |p| p[:med] }.round(2)
      title("Payroll tax and wage summary report", "From #{long(from)} to #{long(to)} from all locations") + [
        [ "Tax types", "Total wages", "Excess wages", "Taxable wages", "Tax amount" ],
        [ "Federal Taxes (941/943/944)", "", "", "", (fit + (ss * 2) + (med * 2)).round(2) ],
        [ "Federal Income Tax", wages, 0, wages, fit ],
        [ "Social Security", wages, 0, wages, ss ],
        [ "Social Security Employer", wages, 0, wages, ss ],
        [ "Medicare", wages, 0, wages, med ],
        [ "Medicare Employer", wages, 0, wages, med ]
      ]
    end

    def write_xls(name, rows)
      path = File.join(@output_dir, name)
      workbook = Spreadsheet::Workbook.new
      sheet = workbook.create_worksheet
      rows.each_with_index { |row, row_index| row.each_with_index { |value, column| sheet[row_index, column] = value } }
      workbook.write(path)
      path
    end

    # One PDF per month (the stub upload takes up to 50 pages), one page per
    # paycheck, with the labeled lines the stub matcher reads. Text only: no
    # signature, MICR line, bank number or full SSN.
    def write_stub_pdfs
      self.class.paychecks.group_by { |p| p[:pay_date].beginning_of_month }.map do |month, paychecks|
        write_stub_pdf(File.join(@output_dir, "Harbor Finch Kitchen pay stubs #{month.strftime('%Y-%m')}.pdf"), paychecks)
      end
    end

    def write_stub_pdf(path, paychecks)
      document = PdfUnicodeFont.document
      paychecks.each_with_index do |p, index|
        document.start_new_page if index.positive?
        document.text COMPANY_NAME, size: 16, style: :bold
        document.text "214 Marine Corps Drive, Hagåtña, GU 96910"
        document.move_down 12
        document.text "Employee: #{p[:person][:first]} #{p[:person][:last]}"
        document.text "Pay period: #{mdy(p[:start_date])} - #{mdy(p[:end_date])}"
        document.text "Check date: #{mdy(p[:pay_date])}"
        document.text(p[:check] ? "Check no. #{p[:check]}" : "Paid by direct deposit")
        document.move_down 8
        document.text format("Hours: %.2f", p[:hours])
        document.text format("Gross pay: $%.2f", p[:gross])
        document.text format("Federal income tax: $%.2f", p[:fit])
        document.text format("Social Security: $%.2f", p[:ss])
        document.text format("Medicare: $%.2f", p[:med])
        document.text format("Net pay: $%.2f", p[:net])
      end
      document.render_file(path)
      path
    end
  end
end
