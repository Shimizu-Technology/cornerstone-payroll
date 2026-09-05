# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::BundleParser do
  after { cleanup_quickbooks_history_uploads }

  it "parses final values and itemized source evidence without recalculation" do
    result = described_class.new(files: quickbooks_history_uploads).call

    expect(result.errors).to be_empty
    expect(result.summary).to include(
      "worker_count" => 2,
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
      "opening_summary_rows" => 1
    )

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

  it "requires all three authoritative source reports" do
    result = described_class.new(files: quickbooks_history_uploads.first(2)).call

    expect(result.errors).to include("Missing required QuickBooks report: Employee details")
    expect(result.paychecks).to be_empty
  end

  it "blocks ambiguous bundles with more than one required report" do
    files = quickbooks_history_uploads
    files << build_quickbooks_xls("Second Payroll Details.xls", payroll_details_rows)

    result = described_class.new(files: files).call

    expect(result.errors.join(" ")).to match(/Multiple Payroll details reports were supplied/)
    expect(result.paychecks).to be_empty
  end

  it "blocks required reports exported from different companies" do
    files = quickbooks_history_uploads.first(2)
    rows = employee_details_rows
    rows[0] = [ "Different Company" ]
    files << build_quickbooks_xls("Employee Details.xls", rows)

    result = described_class.new(files: files).call

    expect(result.errors).to include("Required QuickBooks reports name more than one company")
    expect(result.paychecks).to be_empty
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

  it "rejects unsupported and oversized input before parsing" do
    file = Tempfile.new([ "history", ".txt" ])
    upload = Rack::Test::UploadedFile.new(file.path, "text/plain", true, original_filename: "history.txt")

    expect { described_class.new(files: [ upload ]).call }.to raise_error(ArgumentError, /Unsupported file type/)
  ensure
    file&.close!
  end

  it "classifies supplemental QuickBooks filenames that omit spaces" do
    parser = described_class.new(files: [])

    expect(parser.send(:classify_report, "", "PayrollTaxPayments.xlsx")).to eq("payroll_tax_payments")
    expect(parser.send(:classify_report, "", "TimeOffReport.xlsx")).to eq("time_off")
  end
end
