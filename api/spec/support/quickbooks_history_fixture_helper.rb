# frozen_string_literal: true

require "spreadsheet"
require "tempfile"

module QuickbooksHistoryFixtureHelper
  def quickbooks_history_uploads(suffix: nil)
    @quickbooks_history_tempfiles ||= []
    files = [
      build_quickbooks_xls(
        "Payroll Details#{suffix}.xls",
        payroll_details_rows
      ),
      build_quickbooks_xls(
        "Paycheck History.xls",
        paycheck_history_rows
      ),
      build_quickbooks_xls(
        "Employee Details.xls",
        employee_details_rows
      )
    ]
    files << build_quickbooks_xls("Supplemental #{suffix}.xls", [ [ "Example Company" ], [ "Payroll summary report" ] ]) if suffix
    files
  end

  def quickbooks_history_uploads_with_reversal
    details = payroll_details_rows
    details.insert(
      7,
      [ "Worker, Alice", "07/03/2024", "06/14/2024 - 06/27/2024", -40, -40, -1_000, -900, -100, 50, 50, -950, 200, 100, 80, 20, 25, 25, -725, -100, -80, -20, -50, -50, -1_150 ]
    )
    history = paycheck_history_rows
    history << [ "07/03/2024", "Worker, Alice", -1_000, -725, "Check", "1002", "Void" ]

    [
      build_quickbooks_xls("Payroll Details.xls", details),
      build_quickbooks_xls("Paycheck History.xls", history),
      build_quickbooks_xls("Employee Details.xls", employee_details_rows)
    ]
  end

  def quickbooks_history_uploads_with_duplicate_signature
    details = payroll_details_rows
    details.insert(6, details.fetch(5).dup)
    history = paycheck_history_rows
    history << history.fetch(5).dup.tap { |row| row[5] = "1002" }

    [
      build_quickbooks_xls("Payroll Details.xls", details),
      build_quickbooks_xls("Paycheck History.xls", history),
      build_quickbooks_xls("Employee Details.xls", employee_details_rows)
    ]
  end

  def cleanup_quickbooks_history_uploads
    Array(@quickbooks_history_tempfiles).each do |tempfile|
      tempfile.close
      tempfile.unlink
    end
    @quickbooks_history_tempfiles = []
  end

  private

  def build_quickbooks_xls(filename, rows)
    @quickbooks_history_tempfiles ||= []
    tempfile = Tempfile.new([ "quickbooks-history", ".xls" ])
    workbook = Spreadsheet::Workbook.new
    sheet = workbook.create_worksheet
    rows.each_with_index do |row, row_index|
      row.each_with_index { |value, column_index| sheet[row_index, column_index] = value }
    end
    workbook.write(tempfile.path)
    @quickbooks_history_tempfiles << tempfile
    Rack::Test::UploadedFile.new(tempfile.path, "application/vnd.ms-excel", true, original_filename: filename)
  end

  def payroll_details_rows
    headers = [
      "Name", "Pay date", "Time period", "Hours - total", "Hours - Regular", "Gross pay - total",
      "Gross pay - Regular", "Gross pay - Bonus", "Pretax deductions - total", "Pretax deductions - 401(k) Pre-Tax",
      "Adjusted gross", "Employee taxes - total", "Employee taxes - FIT", "Employee taxes - SS",
      "Employee taxes - Med", "Employee Aftertax deductions - total", "Employee Aftertax deductions - Loan",
      "Net pay", "Employer taxes - total", "Employer taxes - SS", "Employer taxes - Med",
      "Company contributions - total", "Company contributions - 401(k) Pre-Tax", "Total payroll cost"
    ]
    [
      [ "Example Company" ],
      [ "Payroll details report" ],
      [],
      [ "From Jan 01, 2024 to Dec 31, 2024" ],
      headers,
      [ "Worker, Alice", "07/03/2024", "06/14/2024 - 06/27/2024", 40, 40, 1_000, 900, 100, -50, -50, 950, -200, -100, -80, -20, -25, -25, 725, 100, 80, 20, 50, 50, 1_150 ],
      [ "*Worker, Bob", "06/30/2024", "12/29/2023 - 06/27/2024", 80, 80, 2_000, 2_000, 0, 0, 0, 2_000, -400, -200, -160, -40, 0, 0, 1_600, 200, 160, 40, 0, 0, 2_200 ],
      [ "Historical Checks", nil, nil, 80, 80, 2_000 ],
      [ "Total", nil, nil, 120, 120, 3_000 ]
    ]
  end

  def paycheck_history_rows
    [
      [ "Example Company" ],
      [ "Paycheck history report" ],
      [],
      [ "Paychecks from Jan 01, 2024 to Dec 31, 2024" ],
      [ "Pay date", "Name", "Total pay", "Net pay", "Pay method", "Check Number", "Status" ],
      [ "07/03/2024", "Worker, Alice", 1_000, 725, "Check", "1001", "-" ]
    ]
  end

  def employee_details_rows
    [
      [ "Example Company" ],
      [ "Employee details report" ],
      [],
      [ "For all employees" ],
      [ "Personal info", "Hire date", "Work location", "Pay info", "Tax info", "Notes" ],
      [ "Worker, Alice DOB: 01/01/1990", "01/01/2024", "Test location", "Hourly rate: $25.00/hr", "SSN: 000-00-0001", "Synthetic fixture" ],
      [ "*Worker, Bob DOB: 01/01/1980", "01/01/2024", "Test location", "Hourly rate: $25.00/hr", "SSN: 000-00-0002", "Synthetic fixture" ]
    ]
  end
end

RSpec.configure do |config|
  config.include QuickbooksHistoryFixtureHelper
end
