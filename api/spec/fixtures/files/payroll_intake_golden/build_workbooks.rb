# frozen_string_literal: true

# Run from api with bundle exec ruby spec/fixtures/files/payroll_intake_golden/build_workbooks.rb.
# All inputs are literals or the public layout descriptor. No database or real workbooks are read.
require "caxlsx"
require "date"
require "yaml"

module IntakeGoldenWorkbooks
  DIRECTORY = __dir__
  LAYOUT = YAML.safe_load_file(File.expand_path("../../../../config/payroll_intake/mosa_revel.yml", DIRECTORY))
  START_DATE = Date.new(2026, 6, 14)
  END_DATE = Date.new(2026, 6, 27)
  PAY_DATE = Date.new(2026, 7, 3)
  COMPANY_ID = 905_001
  WORKER = [ 905_101, "Testina Mockberry" ].freeze
  NEW_HIRE = [ 905_102, "Novina Fakebrook" ].freeze
  TERMINATED = [ 905_103, "Exita Samplefern" ].freeze
  OWNER = [ 905_104, "Propria Examplemere" ].freeze

  def self.generated(filename, rows, missing_id_column: false, hour_corrections: false)
    layout = LAYOUT.dig("workbook", "generated")
    package = Axlsx::Package.new
    workbook = package.workbook
    workbook.add_worksheet(name: "START HERE") do |sheet|
      sheet.add_row([ "Cornerstone payroll change-only workbook" ])
      sheet.add_row([ "Synthetic intake fixture" ])
      sheet.add_row([])
      layout.fetch("merged_ranges").each { |range| sheet.merge_cells(range) }
      values = [
        "cornerstone-mosa-supplemental/v2", COMPANY_ID, "Synthetic Fixture Restaurant", START_DATE, END_DATE, PAY_DATE,
        1, nil, nil, nil, nil, "NO", "I confirm these payroll changes are complete and accurate."
      ]
      layout.fetch("metadata_labels").zip(values).each { |row| sheet.add_row(row) }
    end
    layout.fetch("sheets").each do |name, definition|
      workbook.add_worksheet(name: name) do |sheet|
        headers = definition.fetch("columns").dup
        headers[0] = nil if missing_id_column && name == "EMPLOYEE CHANGES"
        sheet.add_row(headers)
        rows.fetch(name, []).each { |row| sheet.add_row(row) }
      end
    end
    if hour_corrections
      workbook.add_worksheet(name: "HOUR CORRECTIONS") do |sheet|
        sheet.add_row([ "Employee ID", "Employee", "Regular hours" ])
        sheet.add_row([ *WORKER, 5.25 ])
      end
    end
    package.serialize(File.join(DIRECTORY, "#{filename}.xlsx"))
  end

  def self.legacy
    package = Axlsx::Package.new
    row = [ 1, "Synthetic nickname", "Mockberry", "Testina", "Fixture department" ]
    sheets = {
      "TIPS - BOH" => [ [ "ENTER AMOUNTS HERE" ], [ *row, 12.75 ] ],
      "TIPS - FOH" => [ [ "ENTER AMOUNTS HERE" ], [ *row, "$7.25" ] ],
      "LOANS (NO INSTALLMENTS)" => [ [ "ENTER LOAN AMOUNTS HERE" ], [ *row, 9.50 ] ],
      "INSTALLMENT LOANS" => [ [ "Beginning Balance", "New Loan", "Payment This Period", "Estimated Ending" ], [ *row, nil, nil, nil, nil ] ],
      "BONUSES" => [ [ "Bonus" ], [ *row, 0 ] ]
    }
    sheets.each do |name, (amount_headers, data)|
      package.workbook.add_worksheet(name: name) do |sheet|
        sheet.add_row([ name ])
        sheet.add_row([ "PAY PERIOD ENDING", nil, "6/26/2026 12:00 AM", nil, nil, "6/27/2026" ])
        sheet.add_row([ "PAY DAY", nil, "7/3/2026", nil, nil, "7/10/2026" ])
        sheet.add_row([ nil, "Nickname", "Last Name", "First Name", "Dept", *amount_headers ])
        sheet.add_row(data)
        sheet.add_row([ "Totals", nil, nil, nil, nil, 999.99 ])
      end
    end
    package.workbook.add_worksheet(name: "SUMMARY") { |sheet| sheet.add_row([ "Totals", 999.99 ]) }
    package.serialize(File.join(DIRECTORY, "legacy.xlsx"))
  end

  def self.build
    generated("normal", {
      "EMPLOYEE CHANGES" => [ [ *WORKER, nil, 8.25, 4.50, "YES", "Synthetic tips" ] ],
      "ONE-TIME COMPONENTS" => [ [ *WORKER, "REIMBURSEMENT", "Fixture supplies", 12.34, "reimbursement", nil, PAY_DATE, "Synthetic receipt" ] ]
    })
    generated("overtime_heavy", { "EMPLOYEE CHANGES" => [ [ *WORKER, nil, nil, 11.50, "NO" ] ] })
    generated("new_hire", { "EMPLOYEE CHANGES" => [ [ *NEW_HIRE, nil, 2.50, nil, "NO" ] ] })
    generated("terminated", { "EMPLOYEE CHANGES" => [ [ *TERMINATED, nil, nil, 3.50, "NO" ] ] })
    generated("missing_id_column", { "EMPLOYEE CHANGES" => [ [ nil, WORKER.last, nil, 8.25 ] ] }, missing_id_column: true)
    generated("extra_hour_corrections_sheet", {}, hour_corrections: true)
    generated("loan_totals_mismatch", {
      "DEDUCTIONS & LOANS" => [ [ *WORKER, nil, nil, nil, nil, "KEEP", nil, PAY_DATE, nil, 100, 0, 25, 80 ] ]
    })
    generated("owner_period_pay", {
      "OWNER PERIOD PAY" => [ [ *OWNER, 456.78, "THIS EMPLOYEE ONLY", PAY_DATE, "Synthetic owner instruction" ] ]
    })
    legacy
  end
end

IntakeGoldenWorkbooks.build if $PROGRAM_NAME == __FILE__
