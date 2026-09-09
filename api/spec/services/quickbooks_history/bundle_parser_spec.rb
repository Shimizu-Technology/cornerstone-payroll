# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::BundleParser do
  after { cleanup_quickbooks_history_uploads }

  it "parses final values and itemized source evidence without recalculation" do
    result = described_class.new(files: quickbooks_history_uploads).call

    expect(result.errors).to be_empty
    expect(result.summary).to include(
      "worker_count" => 3,
      "period_count" => 2,
      "paycheck_count" => 2,
      "opening_summary_count" => 1,
      "check_number_count" => 1
    )
    expect(result.summary.dig("totals", "gross_pay")).to eq("3000.0")
    expect(result.summary.dig("totals", "net_pay")).to eq("2325.0")
    expect(result.reconciliation).to include(
      "passed" => true,
      "native_paycheck_rows" => 1,
      "matched_native_rows" => 1,
      "opening_summary_rows" => 1,
      "payroll_summary_rows" => 2,
      "matched_summary_rows" => 2
    )
    expect(result.workers.map { |worker| worker.fetch(:source_status) }.tally).to eq("active" => 2, "inactive" => 1)
    expect(result.workers.map { |worker| worker.fetch(:source_name) }).to include("Worker, Charlie")

    paycheck = result.paychecks.find { |row| row[:source_employee_name] == "Worker, Alice" }
    expect(paycheck).to include(
      gross_pay: 1_000.to_d,
      federal_income_tax: 100.to_d,
      social_security_tax: 80.to_d,
      medicare_tax: 20.to_d,
      net_pay: 725.to_d,
      check_number: "1001",
      reconciliation_status: "matched"
    )
    expect(paycheck[:earnings_breakdown]).to contain_exactly(
      { "label" => "Regular", "amount" => "900.0" },
      { "label" => "Bonus", "amount" => "100.0" }
    )
  end

  it "reconciles annual and quarterly Tax and Wage Summary evidence to the paycheck ledger" do
    result = described_class.new(files: quickbooks_history_uploads + quickbooks_tax_wage_uploads).call

    expect(result.errors).to be_empty
    expect(result.tax_wage_reports.size).to eq(5)
    expect(result.tax_wage_reconciliation).to include("passed" => true, "report_count" => 5)
    expect(result.tax_wage_reconciliation.fetch("checks")).to all(include("passed" => true))
    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include(
        "key" => "fit_total_wages",
        "label" => "FIT total wages",
        "year" => 2024,
        "source_amount" => "2950.0",
        "social_security_wage_base" => "168600.0"
      ),
      include("key" => "employer_ss_tax", "label" => "Employer Social Security tax", "year" => 2024),
      include("key" => "2024_quarterly_rollup", "passed" => true)
    )
  end

  it "marks absent Tax and Wage Summary evidence as unavailable" do
    result = described_class.new(files: quickbooks_history_uploads).call

    expect(result.tax_wage_reconciliation).to include(
      "passed" => false,
      "report_count" => 0,
      "not_available" => true,
      "errors" => []
    )
    expect(result.warnings).to include(match(/Tax and Wage Summary evidence is not available/))
  end

  it "treats an unreadable Tax and Wage Summary as failed evidence, not missing evidence" do
    file = Tempfile.new([ "broken-tax-and-wage", ".xls" ])
    file.write("not a spreadsheet")
    file.rewind
    upload = Rack::Test::UploadedFile.new(
      file.path,
      "application/vnd.ms-excel",
      true,
      original_filename: "Tax and Wage Summary 2024.xls"
    )

    result = described_class.new(files: quickbooks_history_uploads + [ upload ]).call

    expect(result.tax_wage_reconciliation).to include(
      "passed" => false,
      "report_count" => 0,
      "not_available" => false
    )
    expect(result.errors).to include("Tax and Wage Summary 2024.xls could not be read as a Tax and Wage Summary spreadsheet")
  ensure
    file&.close!
  end

  it "matches only the reviewed non-taxable earning-label contract" do
    reviewed_non_taxable_label = described_class::NON_TAXABLE_EARNING_LABEL

    expect("Reimbursable overtime").not_to match(reviewed_non_taxable_label)
    expect("Reimb").to match(reviewed_non_taxable_label)
    expect("Auto Insurance Reimb").to match(reviewed_non_taxable_label)
    expect("Auto Loan Reimbursem").to match(reviewed_non_taxable_label)
    expect("Medicare Reimb Diffe").to match(reviewed_non_taxable_label)
    expect("Rent - Charlie").to match(reviewed_non_taxable_label)
    expect("Loan pay to SP").to match(reviewed_non_taxable_label)
  end

  it "blocks a Tax and Wage Summary that names a different company" do
    rows = annual_tax_wage_rows
    rows.fetch(0)[0] = "Different Company"
    wrong_company = build_quickbooks_xls("Tax_and_Wage_Summary_wrong_company.xls", rows)

    result = described_class.new(
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads.drop(1) + [ wrong_company ]
    ).call

    expect(result.errors).to include(
      "Tax_and_Wage_Summary_wrong_company.xls names a different company than the required QuickBooks reports"
    )
  end

  it "maps Guam unemployment and fingerprints otherwise unknown tax rows" do
    rows = annual_tax_wage_rows
    rows << [ "GU Unemployment Insurance Tax Employer", 3_000, 0, 3_000, 45 ]
    rows << [ "Local payroll assessment", 3_000, 0, 3_000, 12 ]
    annual = build_quickbooks_xls("Tax_and_Wage_Summary_with_local_tax.xls", rows)

    result = described_class.new(
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads.drop(1) + [ annual ]
    ).call
    lines = result.tax_wage_reports.find { |report| report.fetch(:scope) == "annual" }.fetch(:tax_lines)
    unknown = lines.values.find { |line| line["source_label"] == "Local payroll assessment" }

    expect(result.errors).to be_empty
    expect(lines.fetch("state_unemployment_employer")).to include(
      "source_label" => "GU Unemployment Insurance Tax Employer",
      "tax_amount" => "45.0"
    )
    expect(unknown).to include("taxable_wages" => "3000.0", "tax_amount" => "12.0")
  end

  it "warns when QuickBooks reports FUTA for a Guam employer" do
    rows = annual_tax_wage_rows
    rows << [ "FUTA Employer", 3_000, 0, 3_000, 18 ]
    annual = build_quickbooks_xls("Tax_and_Wage_Summary_with_futa.xls", rows)

    result = described_class.new(
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads.drop(1) + [ annual ]
    ).call

    expect(result.warnings.join(" ")).to match(/non-zero FUTA employer tax.*does not apply to Guam employers/)
  end

  it "classifies a full calendar year as annual even when its filename contains a quarter token" do
    annual = build_quickbooks_xls(
      "Tax and Wage Summary Q4 annual.xls",
      annual_tax_wage_rows
    )

    result = described_class.new(files: quickbooks_history_uploads + [ annual ]).call

    expect(result.tax_wage_reports.find { |report| report.fetch(:scope) == "annual" }).to include(scope: "annual")
  end

  it "uses an exact Q1 report as both quarterly evidence and the authoritative YTD report" do
    q1 = build_quickbooks_xls(
      "Tax_and_Wage_Summary_2024_Q1.xls",
      tax_wage_summary_rows(
        start_date: "Jan 01, 2024", end_date: "Mar 31, 2024", fit_wages: 2_950, fit_tax: 300,
        ss_wages: 3_000, ss_tax: 240, medicare_wages: 3_000, medicare_tax: 60, employer_medicare_tax: 60
      )
    )

    result = described_class.new(files: quickbooks_q1_history_uploads + [ q1 ]).call

    expect(result.errors).to be_empty
    expect(result.tax_wage_reports).to contain_exactly(include(scope: "quarterly_year_to_date"))
    expect(result.tax_wage_reconciliation.fetch("checks")).not_to include(
      include("key" => "2024_quarterly_rollup")
    )
    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include("key" => "fit_total_wages", "passed" => true)
    )
  end

  it "keeps an unreconciled Tax and Wage Summary visible as a blocking preview error" do
    result = described_class.new(
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads(q3_fit_wages: 949)
    ).call

    expect(result.tax_wage_reconciliation.fetch("passed")).to be(false)
    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include("key" => "2024_quarterly_rollup", "passed" => false)
    )
    expect(result.errors.join(" ")).to match(/quarterly Tax and Wage Summary reports do not sum/)
  end

  it "records duplicate quarterly evidence as an explicit failed reconciliation check" do
    duplicate_q1 = build_quickbooks_xls(
      "Tax and Wage Summary Q1 duplicate.xls",
      empty_tax_wage_summary_rows("Jan 01, 2024", "Mar 31, 2024")
    )

    result = described_class.new(
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads + [ duplicate_q1 ]
    ).call

    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include("key" => "2024_quarterly_rollup", "passed" => false)
    )
    expect(result.errors.join(" ")).to match(/more than one Tax and Wage Summary for Q1/)
  end

  it "blocks duplicate annual reporting periods before persistence" do
    duplicate_annual = build_quickbooks_xls(
      "Tax and Wage Summary annual duplicate.xls",
      annual_tax_wage_rows
    )

    result = described_class.new(
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads + [ duplicate_annual ]
    ).call

    expect(result.tax_wage_reconciliation.fetch("passed")).to be(false)
    expect(result.errors).to include(
      "Tax and Wage Summary reporting period 01/01/2024 through 12/31/2024 was supplied more than once"
    )
  end

  it "blocks a tax report for a year with no imported payroll" do
    orphan = build_quickbooks_xls(
      "Tax and Wage Summary 2023.xls",
      empty_tax_wage_summary_rows("Jan 01, 2023", "Dec 31, 2023")
    )

    result = described_class.new(
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads + [ orphan ]
    ).call

    expect(result.tax_wage_reconciliation.fetch("passed")).to be(false)
    expect(result.errors).to include(
      "Tax and Wage Summary 2023.xls reporting period contains no imported QuickBooks paychecks"
    )
  end

  it "reconciles a multi-year Tax and Wage Summary through public bundle parsing" do
    result = described_class.new(
      files: quickbooks_two_year_history_uploads + quickbooks_two_year_tax_wage_uploads
    ).call

    expect(result.errors).to be_empty
    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include(
        "key" => "multi_year_rollup_2024-01-01_2025-12-31",
        "passed" => true
      )
    )
  end

  it "blocks a multi-year Tax and Wage Summary that does not equal its annual reports" do
    result = described_class.new(
      files: quickbooks_two_year_history_uploads +
        quickbooks_two_year_tax_wage_uploads(multi_year_fit_wages: 2_949)
    ).call

    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include(
        "key" => "multi_year_rollup_2024-01-01_2025-12-31",
        "passed" => false
      )
    )
    expect(result.errors).to include(
      "Tax_and_Wage_Summary_2024_2025.xls is not fully reconciled by the authoritative annual and YTD reports"
    )
  end

  it "records missing completed-quarter coverage as an explicit failed reconciliation check" do
    reports = quickbooks_tax_wage_uploads.reject { |file| file.original_filename.include?("Q2") }

    result = described_class.new(files: quickbooks_history_uploads + reports).call

    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include("key" => "2024_quarterly_rollup", "passed" => false)
    )
    expect(result.errors.join(" ")).to match(/missing one or more quarterly reports through Q4/)
  end

  it "records a malformed optional Tax and Wage Summary without aborting the payroll preview" do
    malformed = build_quickbooks_xls(
      "Tax_and_Wage_Summary_Broken.xls",
      [ [ "Example Company" ], [ "Payroll tax and wage summary report" ], [], [ "No reporting period" ],
        [ "Tax types", "Total wages", "Excess wages", "Taxable wages", "Tax amount" ] ]
    )

    result = described_class.new(files: quickbooks_history_uploads + [ malformed ]).call

    expect(result.paychecks.size).to eq(2)
    expect(result.tax_wage_reconciliation).to include("passed" => false, "not_available" => false)
    expect(result.tax_wage_reconciliation.fetch("errors").join(" ")).to match(/missing its reporting period/)
    expect(result.warnings.join(" ")).not_to match(/Tax and Wage Summary needs review/)
  end

  it "does not classify ordinary parental leave or loan-forgiveness bonuses as non-taxable" do
    result = described_class.new(
      files: quickbooks_history_uploads_with_non_taxable_labels + quickbooks_tax_wage_uploads(
        fit_wages: 2_880,
        ss_wages: 2_930,
        q3_fit_wages: 880,
        q3_ss_wages: 930
      )
    ).call

    expect(result.errors).to be_empty
    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include("key" => "fit_total_wages", "source_amount" => "2880.0", "passed" => true),
      include("key" => "ss_total_wages", "source_amount" => "2930.0", "passed" => true)
    )
  end

  it "subtracts Section 125 deductions from FICA wages while keeping 401(k) deductions in FICA wages" do
    result = described_class.new(
      files: quickbooks_history_uploads_with_section_125 + quickbooks_tax_wage_uploads(
        fit_wages: 2_925,
        ss_wages: 2_975,
        q3_fit_wages: 925,
        q3_ss_wages: 975
      )
    ).call

    expect(result.errors).to be_empty
    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include("key" => "fit_total_wages", "source_amount" => "2925.0", "passed" => true),
      include("key" => "ss_total_wages", "source_amount" => "2975.0", "passed" => true)
    )
  end

  it "surfaces a missing Social Security wage base as an actionable preview error" do
    stub_const("AnnualTaxConfig::HISTORICAL_SS_WAGE_BASES", {})

    result = described_class.new(files: quickbooks_history_uploads + quickbooks_tax_wage_uploads).call

    expect(result.paychecks.size).to eq(2)
    expect(result.tax_wage_reconciliation.fetch("passed")).to be(false)
    expect(result.errors.join(" ")).to match(/No Social Security wage base is configured for 2024/)
  end

  it "rejects duplicate tax-type rows without aborting the payroll preview" do
    rows = annual_tax_wage_rows(start_date: "Jan 1, 2024")
    federal_income_tax_row = rows.find { |row| row.first.to_s.match?(/federal income tax/i) }
    rows << federal_income_tax_row.dup.tap { |row| row[0] = "fEdErAl InCoMe TaX" }
    duplicate = build_quickbooks_xls("Tax and Wage Summary - 2024.xls", rows)

    result = described_class.new(files: quickbooks_history_uploads + [ duplicate ]).call

    expect(result.paychecks.size).to eq(2)
    expect(result.tax_wage_reconciliation.fetch("errors").join(" ")).to match(
      /same tax line twice: Federal Income Tax and fEdErAl InCoMe TaX/
    )
  end

  it "recognizes explicit quarter tokens without guessing from month prose" do
    filenames = [
      "Tax and Wage Summary Q1.xls",
      "Tax-and-Wage-Summary-Q1.xls",
      "Tax and Wage Summary Jan through Mar.xls"
    ]
    reports = filenames.map do |filename|
      build_quickbooks_xls(
        filename,
        empty_tax_wage_summary_rows("Jan 02, 2024", "Mar 30, 2024")
      )
    end

    result = described_class.new(files: quickbooks_history_uploads + reports).call

    expect(result.tax_wage_reports.pluck(:scope)).to contain_exactly("quarterly", "quarterly", "year_to_date")
  end

  it "reconciles completed quarters when the authoritative report ends mid-quarter" do
    reports = quickbooks_tax_wage_uploads.first(3)
    reports[0] = build_quickbooks_xls(
      "Tax_and_Wage_Summary_2024_YTD.xls",
      tax_wage_summary_rows(
        start_date: "Jan 01, 2024", end_date: "Jul 31, 2024", fit_wages: 2_950, fit_tax: 300,
        ss_wages: 3_000, ss_tax: 240, medicare_wages: 3_000, medicare_tax: 60, employer_medicare_tax: 60
      )
    )

    result = described_class.new(files: quickbooks_history_uploads + reports).call

    expect(result.errors).to be_empty
    expect(result.tax_wage_reconciliation).to include("passed" => true, "not_available" => false)
    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include("key" => "2024_quarterly_rollup", "passed" => true)
    )
  end

  it "rejects a quarter-labeled partial report excluded from the authoritative rollup" do
    reports = quickbooks_tax_wage_uploads.first(3)
    reports[0] = build_quickbooks_xls(
      "Tax_and_Wage_Summary_2024_YTD.xls",
      tax_wage_summary_rows(
        start_date: "Jan 01, 2024", end_date: "Jul 31, 2024", fit_wages: 2_950, fit_tax: 300,
        ss_wages: 3_000, ss_tax: 240, medicare_wages: 3_000, medicare_tax: 60, employer_medicare_tax: 60
      )
    )
    reports << build_quickbooks_xls(
      "Tax_and_Wage_Summary_2024_Q3_partial.xls",
      empty_tax_wage_summary_rows("Jul 01, 2024", "Jul 15, 2024")
    )

    result = described_class.new(files: quickbooks_history_uploads + reports).call

    expect(result.errors).to include(
      "Tax_and_Wage_Summary_2024_Q3_partial.xls is not associated with a reconciled QuickBooks payroll year or reporting window"
    )
  end

  it "keeps Social Security caps distinct from uncapped Medicare wages" do
    details = payroll_details_rows
    headers = details.fetch(4)
    details.fetch(5)[headers.index("Gross pay - total")] = 169_600
    details.fetch(5)[headers.index("Gross pay - Regular")] = 169_500
    details.fetch(5)[headers.index("Adjusted gross")] = 169_550
    history = paycheck_history_rows
    history.fetch(5)[history.fetch(4).index("Total pay")] = 169_600
    files = authoritative_quickbooks_files(details: details, history: history)
    files << build_quickbooks_xls("Tax_and_Wage_Summary_2024.xls", tax_wage_summary_rows(
      start_date: "Jan 01, 2024", end_date: "Dec 31, 2024", fit_wages: 171_550, fit_tax: 300,
      ss_wages: 171_600, ss_excess_wages: 1_000, ss_taxable_wages: 170_600, ss_tax: 240,
      medicare_wages: 171_600, medicare_tax: 60, employer_medicare_tax: 60
    ))
    files << build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q1.xls", empty_tax_wage_summary_rows("Jan 01, 2024", "Mar 31, 2024"))
    files << build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q2.xls", tax_wage_summary_rows(
      start_date: "Apr 01, 2024", end_date: "Jun 30, 2024", fit_wages: 2_000, fit_tax: 200,
      ss_wages: 2_000, ss_tax: 160, medicare_wages: 2_000, medicare_tax: 40, employer_medicare_tax: 40
    ))
    files << build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q3.xls", tax_wage_summary_rows(
      start_date: "Jul 01, 2024", end_date: "Sep 30, 2024", fit_wages: 169_550, fit_tax: 100,
      ss_wages: 169_600, ss_excess_wages: 1_000, ss_taxable_wages: 168_600, ss_tax: 80,
      medicare_wages: 169_600, medicare_tax: 20, employer_medicare_tax: 20
    ))
    files << build_quickbooks_xls("Tax_and_Wage_Summary_2024_Q4.xls", empty_tax_wage_summary_rows("Oct 01, 2024", "Dec 31, 2024"))

    result = described_class.new(files: files).call

    expect(result.errors).to be_empty
    expect(result.tax_wage_reconciliation.fetch("checks")).to include(
      include("key" => "ss_excess_wages", "source_amount" => "1000.0", "passed" => true),
      include("key" => "medicare_wages", "source_amount" => "171600.0", "passed" => true)
    )
  end

  it "requires all five authoritative source reports" do
    result = described_class.new(files: quickbooks_history_uploads.first(2)).call

    expect(result.errors).to include(
      "Missing required QuickBooks report: Employee details",
      "Missing required QuickBooks report: Employee directory",
      "Missing required QuickBooks report: Payroll summary"
    )
    expect(result.paychecks).to be_empty
  end

  it "keeps uploaded tempfiles alive for the full parse" do
    files = quickbooks_history_uploads
    parser = described_class.new(files: files)
    files.clear
    GC.start

    result = parser.call

    expect(result.reconciliation.fetch("passed")).to be(true)
    expect(result.paychecks.size).to eq(2)
  end

  it "derives the same bundle digest regardless of input order, including duplicate filenames" do
    first = Tempfile.new([ "source-evidence-a", ".pdf" ])
    second = Tempfile.new([ "source-evidence-b", ".pdf" ])
    first.write("first evidence")
    second.write("second evidence")
    first.flush
    second.flush
    source_files = [ first, second ].map do |file|
      described_class::SourceFile.new(
        original_filename: "Source Evidence.pdf",
        path: file.path,
        size: file.size,
        source: file
      )
    end
    authoritative = quickbooks_history_uploads

    forward = described_class.new(files: authoritative + source_files).call
    reverse = described_class.new(files: authoritative + source_files.reverse).call

    expect(forward.bundle_digest).to eq(reverse.bundle_digest)
  ensure
    first&.close!
    second&.close!
  end

  it "blocks ambiguous bundles with more than one required report" do
    files = quickbooks_history_uploads
    files << build_quickbooks_xls("Second Payroll Details.xls", payroll_details_rows)

    result = described_class.new(files: files).call

    expect(result.errors.join(" ")).to match(/Multiple Payroll details reports were supplied/)
    expect(result.paychecks).to be_empty
  end

  it "blocks required reports exported from different companies" do
    files = quickbooks_history_uploads
    rows = employee_details_rows
    rows[0] = [ "Different Company" ]
    index = files.index { |file| file.original_filename == "Employee Details.xls" }
    files[index] = build_quickbooks_xls("Employee Details.xls", rows)

    result = described_class.new(files: files).call

    expect(result.errors).to include("Required QuickBooks reports name more than one company")
    expect(result.paychecks).to be_empty
  end

  it "blocks required reports that do not identify their company" do
    files = quickbooks_history_uploads
    rows = employee_details_rows
    rows[0] = [ "" ]
    index = files.index { |file| file.original_filename == "Employee Details.xls" }
    files[index] = build_quickbooks_xls("Employee Details.xls", rows)

    result = described_class.new(files: files).call

    expect(result.errors).to include("Every required QuickBooks report must identify its company")
    expect(result.paychecks).to be_empty
  end

  it "reports unreadable spreadsheets without exposing parser internals" do
    file = Tempfile.new([ "broken-history", ".xls" ])
    file.write("not a spreadsheet")
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, "application/vnd.ms-excel", true, original_filename: "Broken Payroll Details.xls")

    result = described_class.new(files: [ upload ]).call

    expect(result.errors).to include("Broken Payroll Details.xls could not be read as a spreadsheet")
    expect(result.manifest.first.fetch(:parse_error)).to match(/FormatError:/)
    expect(result.manifest.first.fetch(:parse_error)).not_to include(file.path)
  ensure
    file&.close!
  end

  it "blocks a Payroll Summary value that disagrees with Payroll Details" do
    result = described_class.new(files: quickbooks_history_uploads_with_summary_mismatch).call

    expect(result.errors).to include("1 matched Payroll Summary rows disagree with Payroll Details")
    expect(result.reconciliation.fetch("passed")).to be(false)
  end

  it "fails closed instead of converting malformed source money to zero" do
    details = payroll_details_rows
    details[5][5] = "not money"

    expect do
      described_class.new(files: authoritative_quickbooks_files(details: details, history: paycheck_history_rows)).call
    end.to raise_error(ArgumentError, /Payroll Details row 6 Gross pay - total is not a valid number/)
  end

  it "fails closed instead of skipping a named row with an invalid pay date" do
    details = payroll_details_rows
    details[5][1] = "not a date"

    expect do
      described_class.new(files: authoritative_quickbooks_files(details: details, history: paycheck_history_rows)).call
    end.to raise_error(ArgumentError, /Payroll Details row 6 Pay date is missing or invalid/)
  end

  it "rejects a paycheck whose pay date precedes the period end before persistence" do
    details = payroll_details_rows
    details[5][1] = "06/20/2024"

    expect do
      described_class.new(files: authoritative_quickbooks_files(details: details, history: paycheck_history_rows)).call
    end.to raise_error(ArgumentError, /Payroll Details row 6 pay date must be on or after period end/)
  end

  it "measures path inputs by file bytes rather than path length" do
    uploads = quickbooks_history_uploads
    paths = uploads.map(&:path)

    result = described_class.new(files: paths).call

    expect(result.manifest.map { |entry| entry.fetch(:byte_size) }).to eq(paths.map { |path| File.size(path) })
  end

  it "preserves the direction of void and reversal amounts" do
    result = described_class.new(files: quickbooks_history_uploads_with_reversal).call
    reversal = result.paychecks.find { |row| row[:gross_pay].negative? }

    expect(result.errors).to be_empty
    expect(reversal).to include(
      gross_pay: -1_000.to_d,
      pretax_deductions: -50.to_d,
      employee_taxes: -200.to_d,
      federal_income_tax: -100.to_d,
      after_tax_deductions: -25.to_d,
      net_pay: -725.to_d,
      employer_taxes: -100.to_d,
      employer_contributions: -50.to_d,
      total_payroll_cost: -1_150.to_d
    )
    expect(reversal.fetch(:employee_tax_breakdown)).to include({ "label" => "FIT", "amount" => "-100.0" })
  end

  it "stages duplicate paycheck signatures deterministically but blocks apply for manual review" do
    result = described_class.new(files: quickbooks_history_uploads_with_duplicate_signature).call
    duplicate_rows = result.paychecks.select { |row| row[:source_employee_name] == "Worker, Alice" }

    expect(duplicate_rows.size).to eq(2)
    expect(duplicate_rows.map { |row| row.fetch(:external_key) }.uniq.size).to eq(2)
    expect(duplicate_rows.map { |row| row.fetch(:check_number) }).to contain_exactly("1001", "1002")
    expect(result.errors).to include("2 duplicate paycheck signature group(s) require manual source review")
    expect(result.reconciliation.fetch("passed")).to be(false)
  end

  it "rejects distinct source workers whose names normalize to the same identity" do
    expect do
      described_class.new(files: quickbooks_history_uploads_with_worker_name_collision).call
    end.to raise_error(ArgumentError, /normalized employee name collision/)
  end

  it "rejects duplicate Employee Details identities instead of silently keeping one" do
    details = employee_details_rows
    details << details.fetch(5).dup

    expect do
      described_class.new(files: authoritative_quickbooks_files(
        details: payroll_details_rows,
        history: paycheck_history_rows,
        employee_details: details
      )).call
    end.to raise_error(ArgumentError, /normalized Employee Details name collision/)
  end

  it "derives the opening-summary warning range from the source rows" do
    result = described_class.new(files: quickbooks_history_uploads_with_custom_opening_range).call

    expect(result.warnings).to include(
      "1 employee opening-balance rows summarize 01/01/2024 through 05/31/2024. They preserve QuickBooks totals but are not original paycheck-level periods."
    )
  end

  it "rejects unsupported and oversized input before parsing" do
    file = Tempfile.new([ "history", ".txt" ])
    upload = Rack::Test::UploadedFile.new(file.path, "text/plain", true, original_filename: "history.txt")

    expect { described_class.new(files: [ upload ]).call }.to raise_error(ArgumentError, /Unsupported file type/)
  ensure
    file&.close!
  end

  it "rejects an empty export before retaining it as evidence" do
    file = Tempfile.new([ "empty-history", ".xls" ])
    upload = Rack::Test::UploadedFile.new(
      file.path,
      "application/vnd.ms-excel",
      true,
      original_filename: "PayrollDetails.xls"
    )

    expect { described_class.new(files: [ upload ]).call }.to raise_error(
      ArgumentError,
      "PayrollDetails.xls is empty"
    )
  ensure
    file&.close!
  end

  it "classifies supplemental QuickBooks filenames through the public bundle interface" do
    files = quickbooks_history_uploads
    files << build_quickbooks_xls("PayrollTaxPayments.xls", [ [ "Example Company" ], [ "Payroll tax payments report" ] ])
    files << build_quickbooks_xls("TimeOffReport.xls", [ [ "Example Company" ], [ "Time off report" ] ])

    result = described_class.new(files: files).call
    types = result.manifest.map { |entry| entry.fetch(:report_type) }

    expect(types).to include("payroll_tax_payments", "time_off")
  end

  it "warns on an unreadable supplemental spreadsheet without blocking required reports" do
    file = Tempfile.new([ "broken-time-off", ".xls" ])
    file.write("not a spreadsheet")
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, "application/vnd.ms-excel", true, original_filename: "TimeOffReport.xls")

    result = described_class.new(files: quickbooks_history_uploads + [ upload ]).call

    expect(result.errors).to be_empty
    expect(result.warnings).to include(
      "Supplemental spreadsheet(s) could not be parsed: TimeOffReport.xls. They remain fingerprinted as source evidence."
    )
  ensure
    file&.close!
  end
end
