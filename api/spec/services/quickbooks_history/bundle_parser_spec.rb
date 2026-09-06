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
