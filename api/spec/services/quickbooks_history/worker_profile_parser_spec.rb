# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::WorkerProfileParser do
  def worker(source_name: "Worker, Alice", source_status: "active", pay_info:, tax_info: nil, directory: {})
    HistoricalWorker.new(
      id: 41,
      source_name: source_name,
      source_status: source_status,
      private_snapshot: JSON.generate(
        {
          "Pay info" => pay_info,
          "Tax info" => tax_info || "SSN: 000-00-0001 Fed: Single or Married Filing Separately",
          "_employee_directory" => {
            "Birth date" => "01/02/1990",
            "Email" => "worker@example.test",
            "Home address" => "452 Wrong Way, Henderson, NV 89015"
          }.merge(directory)
        }
      )
    )
  end

  it "prepares production-shaped hourly pay, tax, retirement, and current deduction setup" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Joint Kitchen: $11.25/hr Pay method: Check " \
                  "Deductions: Health Insurance: $126.00 401(k) After Tax: 4.00% " \
                  "Loan (review): $75.00 Contributions: 401(k) After Tax: 4.00% Time off: None"
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.errors).to be_empty
    expect(parsed.employee_attributes).to include(
      first_name: "Alice",
      last_name: "Worker",
      employment_type: "hourly",
      pay_rate: 11.25.to_d,
      filing_status: "single",
      roth_retirement_rate: 0.04.to_d,
      employer_roth_match_rate: 0.04.to_d,
      address_line1: nil,
      configuration_review_status: "needs_review"
    )
    expect(parsed.wage_rates).to contain_exactly(
      hash_including(label: "Hourly rate", rate: 11.25.to_d, is_primary: true),
      hash_including(label: "Joint Kitchen", rate: 11.25.to_d, is_primary: false)
    )
    expect(parsed.payroll_fields).to contain_exactly(
      hash_including(name: "Health Insurance", category: "insurance", amount: 126.to_d),
      hash_including(name: "Loan (review)", category: "loan", amount: 75.to_d)
    )
    expect(parsed.review_items.pluck("code")).to include(
      "verify_hire_date",
      "quickbooks_nevada_address_suppressed",
      "obligation_terms_missing"
    )
  end

  it "keeps comma-separated street details while parsing the city from the right" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        directory: { "Home address" => "123 Main Street, Apt 4B, Hagatna, GU 96910" }
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes).to include(
      address_line1: "123 Main Street, Apt 4B",
      city: "Hagatna",
      state: "GU",
      zip: "96910"
    )
  end

  it "does not copy a partially parsed address when the state and ZIP are invalid" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        directory: { "Home address" => "123 Main Street, Hagatna, Guam" }
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes.values_at(:address_line1, :city, :state, :zip)).to eq([ nil, nil, nil, nil ])
    expect(parsed.review_items.pluck("code")).to include("employee_address_missing")
  end

  it "uses variable salary for commission-only workers and flags legacy withholding allowances" do
    parsed = described_class.new(
      worker: worker(
        source_name: "Owner, Example Middle",
        pay_info: "Pay type: Commission Only Pay method: Check Deductions: 401(k) Pre-Tax: $927.91 Contributions: 401(k) Pre-Tax: 4.00% Time off: None",
        tax_info: "SSN: 000-00-0001 Fed: Single Withholding allowances: 2"
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.errors).to be_empty
    expect(parsed.employee_attributes).to include(
      first_name: "Example",
      middle_name: "Middle",
      last_name: "Owner",
      employment_type: "salary",
      salary_type: "variable",
      pay_rate: 0.to_d,
      allowances: 2,
      employer_retirement_match_rate: 0.04.to_d
    )
    expect(parsed.payroll_fields).to contain_exactly(
      hash_including(name: "401(k) Pre-Tax", tax_treatment: "pre_tax_deduction", amount: 927.91.to_d)
    )
    expect(parsed.review_items.pluck("code")).to include("commission_only_variable_pay", "legacy_w4_allowances")
  end

  it "does not activate QuickBooks placeholder loans" do
    parsed = described_class.new(
      worker: worker(pay_info: "Hourly rate: $9.25/hr Pay method: Check Deductions: Loan: $1.00 Contributions: None Time off: None"),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.payroll_fields).to be_empty
    expect(parsed.warnings).to contain_exactly("A QuickBooks placeholder deduction was intentionally not activated")
  end

  it "blocks unknown positive deductions instead of guessing their tax treatment" do
    parsed = described_class.new(
      worker: worker(pay_info: "Hourly rate: $9.25/hr Pay method: Check Deductions: Mystery: $10.00 Contributions: None Time off: None"),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.errors).to include(/needs an explicit tax\/category mapping/)
  end
end
