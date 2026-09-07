# frozen_string_literal: true

require "spreadsheet"
require "tempfile"

module QuickbooksHistoryFixtureHelper
  def quickbooks_history_uploads(suffix: nil)
    authoritative_quickbooks_files(
      details: payroll_details_rows,
      history: paycheck_history_rows,
      suffix: suffix
    )
  end

  def quickbooks_history_uploads_with_reversal
    details = payroll_details_rows
    details.insert(
      7,
      [ "Worker, Alice", "07/03/2024", "06/14/2024 - 06/27/2024", -40, -40, -1_000, -900, -100, 50, 50, -950, 200, 100, 80, 20, 25, 25, -725, -100, -80, -20, -50, -50, -1_150 ]
    )
    history = paycheck_history_rows
    history << [ "07/03/2024", "Worker, Alice", -1_000, -725, "Check", "1002", "Void" ]

    authoritative_quickbooks_files(details: details, history: history)
  end

  def quickbooks_history_uploads_with_duplicate_signature
    details = payroll_details_rows
    details.insert(6, details.fetch(5).dup)
    history = paycheck_history_rows
    history << history.fetch(5).dup.tap { |row| row[5] = "1002" }

    authoritative_quickbooks_files(details: details, history: history)
  end

  def quickbooks_history_uploads_with_worker_name_collision
    details = payroll_details_rows
    details.insert(
      6,
      [ "Worker Alice", "07/17/2024", "06/28/2024 - 07/11/2024", 40, 40, 1_100, 1_100, 0, 0, 0, 1_100, -220, -110, -88, -22, 0, 0, 880, 110, 88, 22, 0, 0, 1_210 ]
    )
    history = paycheck_history_rows
    history << [ "07/17/2024", "Worker Alice", 1_100, 880, "Check", "1002", "-" ]

    authoritative_quickbooks_files(details: details, history: history)
  end

  def quickbooks_history_uploads_with_custom_opening_range
    details = payroll_details_rows
    opening_row = details.find { |row| row[0] == "*Worker, Bob" }
    opening_row[2] = "01/01/2024 - 05/31/2024"

    authoritative_quickbooks_files(details: details, history: paycheck_history_rows)
  end

  def quickbooks_history_uploads_with_summary_mismatch
    details = payroll_details_rows
    summary = payroll_summary_rows(details)
    summary[5][6] = -199

    authoritative_quickbooks_files(details: details, history: paycheck_history_rows, summary: summary)
  end

  def quickbooks_history_uploads_with_section_125
    quickbooks_history_uploads_with_extra_deduction(
      label: "Pretax deductions - Section 125 Health Pre-Tax",
      amount: -25,
      total_column: "Pretax deductions - total",
      deduction_total: -75,
      adjusted_gross: 925,
      net_pay: 700
    )
  end

  def quickbooks_history_uploads_with_non_taxable_labels
    details = payroll_details_rows
    labels = [
      "Gross pay - Parental Leave",
      "Gross pay - Loan Forgiveness Bonus",
      "Gross pay - Auto Loan Reimbursement",
      "Gross pay - Loan - Charlie"
    ]
    columns = labels.map do |label|
      column = details.fetch(4).length
      details.fetch(4) << label
      column
    end
    details.fetch(5)[details.fetch(4).index("Gross pay - Regular")] = 800
    columns.zip([ 10, 20, 30, 40 ]).each { |column, value| details.fetch(5)[column] = value }
    columns.each { |column| details.fetch(6)[column] = 0 }
    columns.each { |column| details.fetch(7)[column] = 0 }
    columns.zip([ 10, 20, 30, 40 ]).each { |column, value| details.fetch(8)[column] = value }

    authoritative_quickbooks_files(details: details, history: paycheck_history_rows)
  end

  def quickbooks_history_uploads_with_roth_and_loan
    quickbooks_history_uploads_with_extra_deduction(
      label: "Employee Aftertax deductions - Roth 401(k) Loan",
      amount: -50,
      total_column: "Employee Aftertax deductions - total",
      deduction_total: -75,
      net_pay: 675
    )
  end

  def quickbooks_history_uploads_with_tip_label(label)
    details = payroll_details_rows
    headers = details.fetch(4)
    headers[headers.index("Gross pay - Bonus")] = "Gross pay - #{label}"

    authoritative_quickbooks_files(details: details, history: paycheck_history_rows)
  end

  # Q1 and Q4 are empty and Q2 is fixed at 2,000. Annual FIT and SS wages
  # reconcile only when they equal Q2 plus the matching Q3 value.
  def quickbooks_tax_wage_uploads(
    fit_wages: 2_950,
    ss_wages: 3_000,
    q3_fit_wages: 950,
    q3_ss_wages: 1_000
  )
    [
      build_quickbooks_xls(
        "Tax_and_Wage_Summary_2024.xls",
        annual_tax_wage_rows(fit_wages: fit_wages, ss_wages: ss_wages, medicare_wages: ss_wages)
      ),
      build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q1.xls", empty_tax_wage_summary_rows("Jan 01, 2024", "Mar 31, 2024")),
      build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q2.xls", tax_wage_summary_rows(
        start_date: "Apr 01, 2024", end_date: "Jun 30, 2024", fit_wages: 2_000, fit_tax: 200,
        ss_wages: 2_000, ss_tax: 160, medicare_wages: 2_000, medicare_tax: 40, employer_medicare_tax: 40
      )),
      build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q3.xls", tax_wage_summary_rows(
        start_date: "Jul 01, 2024", end_date: "Sep 30, 2024", fit_wages: q3_fit_wages, fit_tax: 100,
        ss_wages: q3_ss_wages, ss_tax: 80, medicare_wages: q3_ss_wages, medicare_tax: 20, employer_medicare_tax: 20
      )),
      build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q4.xls", empty_tax_wage_summary_rows("Oct 01, 2024", "Dec 31, 2024"))
    ]
  end

  def quickbooks_two_year_history_uploads
    details = payroll_details_rows
    details.fetch(3)[0] = "From Jan 01, 2024 to Dec 31, 2025"
    bob = details.find { |row| row[0] == "*Worker, Bob" }
    bob[1] = "06/30/2025"
    bob[2] = "01/01/2025 - 06/27/2025"
    history = paycheck_history_rows
    history.fetch(3)[0] = "Paychecks from Jan 01, 2024 to Dec 31, 2025"

    authoritative_quickbooks_files(details: details, history: history)
  end

  def quickbooks_q1_history_uploads
    details = payroll_details_rows
    details.fetch(3)[0] = "From Jan 01, 2024 to Mar 31, 2024"
    alice = details.find { |row| row[0] == "Worker, Alice" }
    alice[1] = "03/15/2024"
    alice[2] = "03/01/2024 - 03/14/2024"
    bob = details.find { |row| row[0] == "*Worker, Bob" }
    bob[1] = "03/31/2024"
    bob[2] = "01/01/2024 - 03/30/2024"
    history = paycheck_history_rows
    history.fetch(3)[0] = "Paychecks from Jan 01, 2024 to Mar 31, 2024"
    history.fetch(5)[0] = "03/15/2024"

    authoritative_quickbooks_files(details: details, history: history)
  end

  def quickbooks_two_year_tax_wage_uploads(multi_year_fit_wages: 2_950)
    reports = []
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2024.xls", tax_wage_summary_rows(
      start_date: "Jan 01, 2024", end_date: "Dec 31, 2024", fit_wages: 950, fit_tax: 100,
      ss_wages: 1_000, ss_tax: 80, medicare_wages: 1_000, medicare_tax: 20, employer_medicare_tax: 20
    ))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q1.xls", empty_tax_wage_summary_rows("Jan 01, 2024", "Mar 31, 2024"))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q2.xls", empty_tax_wage_summary_rows("Apr 01, 2024", "Jun 30, 2024"))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q3.xls", tax_wage_summary_rows(
      start_date: "Jul 01, 2024", end_date: "Sep 30, 2024", fit_wages: 950, fit_tax: 100,
      ss_wages: 1_000, ss_tax: 80, medicare_wages: 1_000, medicare_tax: 20, employer_medicare_tax: 20
    ))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q4.xls", empty_tax_wage_summary_rows("Oct 01, 2024", "Dec 31, 2024"))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2025.xls", tax_wage_summary_rows(
      start_date: "Jan 01, 2025", end_date: "Dec 31, 2025", fit_wages: 2_000, fit_tax: 200,
      ss_wages: 2_000, ss_tax: 160, medicare_wages: 2_000, medicare_tax: 40, employer_medicare_tax: 40
    ))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2025_Q1.xls", empty_tax_wage_summary_rows("Jan 01, 2025", "Mar 31, 2025"))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2025_Q2.xls", tax_wage_summary_rows(
      start_date: "Apr 01, 2025", end_date: "Jun 30, 2025", fit_wages: 2_000, fit_tax: 200,
      ss_wages: 2_000, ss_tax: 160, medicare_wages: 2_000, medicare_tax: 40, employer_medicare_tax: 40
    ))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2025_Q3.xls", empty_tax_wage_summary_rows("Jul 01, 2025", "Sep 30, 2025"))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2025_Q4.xls", empty_tax_wage_summary_rows("Oct 01, 2025", "Dec 31, 2025"))
    reports << build_quickbooks_xls("Tax_and_Wage_Summary_2024_2025.xls", tax_wage_summary_rows(
      start_date: "Jan 01, 2024", end_date: "Dec 31, 2025", fit_wages: multi_year_fit_wages, fit_tax: 300,
      ss_wages: 3_000, ss_tax: 240, medicare_wages: 3_000, medicare_tax: 60, employer_medicare_tax: 60
    ))
    reports
  end

  def annual_tax_wage_rows(**overrides)
    tax_wage_summary_rows(**{
      start_date: "Jan 01, 2024",
      end_date: "Dec 31, 2024",
      fit_wages: 2_950,
      fit_tax: 300,
      ss_wages: 3_000,
      ss_tax: 240,
      medicare_wages: 3_000,
      medicare_tax: 60,
      employer_medicare_tax: 60
    }.merge(overrides))
  end

  def review_historical_workers_as_archive_only(batch, actor:)
    batch.historical_workers.find_each do |worker|
      QuickbooksHistory::MappingService.new(worker: worker, employee: nil, actor: actor, archive_only: true).call
    end
  end

  def approve_historical_cutover(batch, actor:)
    evidence = { "version" => 1, "passed" => true, "exceptions" => [] }
    HistoricalImportCutoverReview.create!(
      company: batch.company,
      historical_import_batch: batch,
      status: "approved",
      evidence: evidence,
      evidence_digest: Digest::SHA256.hexdigest(JSON.generate(evidence)),
      verified_at: Time.current,
      verified_by: actor,
      exception_dispositions: {},
      attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true),
      approval_notes: "No remaining limitations in this lifecycle test.",
      approval_acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT,
      approved_at: Time.current,
      approved_by: actor
    )
  end

  def cleanup_quickbooks_history_uploads
    Array(@quickbooks_history_tempfiles).each do |tempfile|
      tempfile.close
      tempfile.unlink
    end
    @quickbooks_history_tempfiles = []
  end

  private

  def quickbooks_history_uploads_with_extra_deduction(
    label:, amount:, total_column:, deduction_total:, net_pay:, adjusted_gross: nil
  )
    details = payroll_details_rows
    headers = details.fetch(4)
    deduction_column = headers.length
    headers << label
    details.fetch(5)[headers.index(total_column)] = deduction_total
    details.fetch(5)[headers.index("Adjusted gross")] = adjusted_gross if adjusted_gross
    details.fetch(5)[headers.index("Net pay")] = net_pay
    details.fetch(5)[deduction_column] = amount
    details.fetch(6)[deduction_column] = 0
    details.fetch(7)[deduction_column] = 0
    details.fetch(8)[deduction_column] = amount
    history = paycheck_history_rows
    history.fetch(5)[history.fetch(4).index("Net pay")] = net_pay

    authoritative_quickbooks_files(details: details, history: history)
  end

  def authoritative_quickbooks_files(details:, history:, employee_details: nil, summary: nil, suffix: nil)
    employee_details ||= employee_details_rows
    summary ||= payroll_summary_rows(details)
    [
      build_quickbooks_xls("Payroll Details#{suffix}.xls", details),
      build_quickbooks_xls("Paycheck History.xls", history),
      build_quickbooks_xls("Employee Details.xls", employee_details),
      build_quickbooks_xls("Employee Directory.xls", employee_directory_rows),
      build_quickbooks_xls("Payroll Summary.xls", summary)
    ]
  end

  def build_quickbooks_xls(filename, rows)
    @quickbooks_history_tempfiles ||= []
    tempfile = Tempfile.new([ "quickbooks-history", ".xls" ])
    tempfile.close
    workbook = Spreadsheet::Workbook.new
    sheet = workbook.create_worksheet
    rows.each_with_index do |row, row_index|
      row.each_with_index { |value, column_index| sheet[row_index, column_index] = value }
    end
    workbook.write(tempfile.path)
    @quickbooks_history_tempfiles << tempfile
    Rack::Test::UploadedFile.new(tempfile.path, "application/vnd.ms-excel", true, original_filename: filename)
  end

  def tax_wage_summary_rows(
    start_date:, end_date:, fit_wages:, fit_tax:, ss_wages:, ss_tax:, medicare_tax:, employer_medicare_tax:,
    medicare_wages:, ss_excess_wages: 0, ss_taxable_wages: ss_wages - ss_excess_wages
  )
    [
      [ "Example Company" ],
      [ "Payroll tax and wage summary report" ],
      [],
      [ "From #{start_date} to #{end_date} from all locations" ],
      [ "Tax types", "Total wages", "Excess wages", "Taxable wages", "Tax amount" ],
      [ "Federal Taxes (941/943/944)", "", "", "", fit_tax + (ss_tax * 2) + medicare_tax + employer_medicare_tax ],
      [ "Federal Income Tax", fit_wages, 0, fit_wages, fit_tax ],
      [ "Social Security", ss_wages, ss_excess_wages, ss_taxable_wages, ss_tax ],
      [ "Social Security Employer", ss_wages, ss_excess_wages, ss_taxable_wages, ss_tax ],
      [ "Medicare", medicare_wages, 0, medicare_wages, medicare_tax ],
      [ "Medicare Employer", medicare_wages, 0, medicare_wages, employer_medicare_tax ]
    ]
  end

  def empty_tax_wage_summary_rows(start_date, end_date)
    [
      [ "Example Company" ],
      [ "Payroll tax and wage summary report" ],
      [],
      [ "From #{start_date} to #{end_date} from all locations" ],
      [ "Tax types", "Total wages", "Excess wages", "Taxable wages", "Tax amount" ],
      [ "", "", "", "", "" ]
    ]
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
      [ "Worker, Alice DOB: 01/01/1990", "01/01/2024", "Test location", "Hourly rate: $25.00/hr Joint: $25.00/hr Pay method: Check Deductions: Health Insurance: $105.00 401(k) After Tax: 4.00% Contributions: 401(k) After Tax: 4.00% Time off: None", "SSN: 000-00-0001 Fed: Single or Married Filing Separately", "Synthetic fixture" ],
      [ "*Worker, Bob DOB: 01/01/1980", "01/01/2024", "Test location", "Hourly rate: $25.00/hr Pay method: Check Deductions: None Contributions: None Time off: None", "SSN: 000-00-0002 Fed: Single", "Synthetic fixture" ],
      [ "Worker, Charlie DOB: 01/01/1985", "02/01/2024", "Test location", "Pay type: Commission Only Pay method: Check Deductions: Loan (example): $25.00 Contributions: None Time off: None", "SSN: 000-00-0003 Fed: Head of Household", "No paycheck in export window" ]
    ]
  end

  def employee_directory_rows
    [
      [ "Example Company" ],
      [ "Employee directory report" ],
      [],
      [ "For all employees from all locations" ],
      [ "Name", "Birth date", "Email", "Work phone", "Home phone", "Mobile", "Home address", "Work location", "Hire date" ],
      [ "Worker, Alice", "01/01/1990", "alice@example.test", "", "", "", "", "Test location", "01/01/2024" ],
      [ "*Worker, Bob", "01/01/1980", "", "", "", "", "", "Test location", "01/01/2024" ],
      [ "Worker, Charlie", "01/01/1985", "charlie@example.test", "", "", "", "", "Test location", "02/01/2024" ]
    ]
  end

  def payroll_summary_rows(details)
    summary_rows = details.drop(5).filter_map do |row|
      name = row[0].to_s
      next if name.blank? || name.in?([ "Historical Checks", "Total" ])

      [ row[1], row[0], row[3], row[5], row[8], 0, row[11], row[15], row[17], row[18], row[21], row[23], "" ]
    end
    [
      [ "Example Company" ],
      [ "Payroll summary report" ],
      [],
      [ "From Jan 01, 2024 to Dec 31, 2024 for all employees from all locations" ],
      [ "Pay date", "Name", "Hours", "Gross pay", "Pretax deductions", "Other pay", "Employee taxes", "Aftertax deduction", "Net pay", "Employer taxes", "Company contributions", "Total payroll cost", "Pay method" ],
      *summary_rows
    ]
  end
end

RSpec.configure do |config|
  config.include QuickbooksHistoryFixtureHelper
  config.after do
    cleanup_quickbooks_history_uploads if defined?(@quickbooks_history_tempfiles)
  end
end
