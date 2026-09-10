# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::WorkerProfileParser do
  def worker(pay_info:, source_name: "Worker, Alice", source_status: "active", tax_info: nil, directory: {})
    build(
      :historical_worker,
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

  it "retains explicit advanced W-4 inputs and signed-document provenance without choosing an effective date" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        tax_info: "SSN: 000-00-0001 Fed: Single Claim dependents amount: $2,000 " \
          "Multiple jobs: Yes Other income: $1,200.50 Deductions: $300 Extra withholding: $25.75 " \
          "W-4 form revision: 2025 W-4 signed date: 2025-10-20"
      ), pay_frequency: "biweekly"
    ).call

    expect(parsed.errors).to be_empty
    expect(parsed.employee_attributes).to include(
      w4_dependent_credit: 2000.to_d, w4_step2_multiple_jobs: true,
      w4_step4a_other_income: 1200.50.to_d, w4_step4b_deductions: 300.to_d,
      additional_withholding: 25.75.to_d, w4_form_version: 2025,
      w4_signed_on: Date.new(2025, 10, 20), w4_source_reference: "QuickBooks retained worker 41 / Tax info"
    )
    expect(parsed.employee_attributes).not_to have_key(:w4_effective_on)
    expect(parsed.review_items.pluck("code")).not_to include("w4_source_inputs_unverified")
  end

  it "flags absent W-4 inputs instead of treating defaults as verified elections" do
    parsed = described_class.new(
      worker: worker(pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None"),
      pay_frequency: "biweekly"
    ).call

    item = parsed.review_items.find { |review| review["code"] == "w4_source_inputs_unverified" }
    expect(item.fetch("fields")).to contain_exactly(
      "w4_dependent_credit", "w4_step2_multiple_jobs", "w4_step4a_other_income", "w4_step4b_deductions",
      "additional_withholding", "w4_form_version", "w4_signed_on"
    )
    expect(parsed.employee_attributes[:w4_signed_on]).to be_nil
  end

  it "recognizes explicitly supplied zero amounts and an unchecked multiple-jobs box" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        tax_info: "SSN: 000-00-0001 Fed: Single Claim dependents amount: $0 " \
          "Multiple jobs: No Other income: 0 Deductions: 0 Additional withholding: 0 W4 year: 2025 Signed date: 10/20/2025"
      ), pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes[:w4_step2_multiple_jobs]).to be(false)
    expect(parsed.employee_attributes[:w4_signed_on]).to eq(Date.new(2025, 10, 20))
    expect(parsed.review_items.pluck("code")).not_to include("w4_source_inputs_unverified")
  end

  it "distinguishes a malformed employee directory snapshot from a missing one" do
    [ [ "not", "an", "object" ], "", false ].each do |malformed_directory|
      malformed_worker = build(
        :historical_worker,
        id: 42,
        source_name: "Worker, Alice",
        source_status: "active",
        private_snapshot: JSON.generate(
          "Pay info" => "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
          "Tax info" => "SSN: 000-00-0001 Fed: Single or Married Filing Separately",
          "_employee_directory" => malformed_directory
        )
      )

      parsed = described_class.new(worker: malformed_worker, pay_frequency: "biweekly").call

      expect(parsed.errors).to include(/employee directory setup is malformed/)
      expect(parsed.errors).not_to include(/employee directory setup is missing/)
    end
  end

  it "reports missing setup for an absent or empty employee directory snapshot" do
    [
      {
        "Pay info" => "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        "Tax info" => "SSN: 000-00-0001 Fed: Single or Married Filing Separately"
      },
      {
        "Pay info" => "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        "Tax info" => "SSN: 000-00-0001 Fed: Single or Married Filing Separately",
        "_employee_directory" => {}
      }
    ].each do |snapshot|
      missing_worker = build(
        :historical_worker,
        id: 43,
        source_name: "Worker, Alice",
        source_status: "active",
        private_snapshot: JSON.generate(snapshot)
      )

      parsed = described_class.new(worker: missing_worker, pay_frequency: "biweekly").call

      expect(parsed.errors).to include(/employee directory setup is missing/)
      expect(parsed.errors).not_to include(/employee directory setup is malformed/)
    end
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

  it "accepts every supported U.S. territory code in a complete address" do
    %w[AS GU MP PR VI].each do |region_code|
      parsed = described_class.new(
        worker: worker(
          pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
          directory: { "Home address" => "123 Main Street, Example City, #{region_code} 96910" }
        ),
        pay_frequency: "biweekly"
      ).call

      expect(parsed.employee_attributes.values_at(:address_line1, :city, :state, :zip)).to eq(
        [ "123 Main Street", "Example City", region_code, "96910" ]
      )
    end
  end

  it "rejects an unknown region code even when the address has a valid-looking ZIP" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        directory: { "Home address" => "123 Main Street, Hagatna, XX 96910" }
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes.values_at(:address_line1, :city, :state, :zip)).to eq([ nil, nil, nil, nil ])
    expect(parsed.review_items.pluck("code")).to include("employee_address_missing")
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

  it "does not mistake an address without comma-separated city details for a state" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        directory: { "Home address" => "123 Main Street Hagatna GU 96910" }
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes.values_at(:address_line1, :city, :state, :zip)).to eq([ nil, nil, nil, nil ])
    expect(parsed.review_items.pluck("code")).to include("employee_address_missing")
  end

  it "does not mistake a street-only component for the city" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        directory: { "Home address" => "123 Main Street, GU 96910" }
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes.values_at(:address_line1, :city, :state, :zip)).to eq([ nil, nil, nil, nil ])
    expect(parsed.review_items.pluck("code")).to include("employee_address_missing")
  end

  it "suppresses a Nevada address even when QuickBooks omitted the ZIP code" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        directory: { "Home address" => "123 Main Street, Henderson, Nevada" }
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes.values_at(:address_line1, :city, :state, :zip)).to eq([ nil, nil, nil, nil ])
    expect(parsed.review_items.pluck("code")).to include("quickbooks_nevada_address_suppressed")
  end

  it "suppresses a Nevada address when the exported region includes an extra prefix" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        directory: { "Home address" => "123 Main Street, Henderson, Clark County Nevada" }
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes.values_at(:address_line1, :city, :state, :zip)).to eq([ nil, nil, nil, nil ])
    expect(parsed.review_items.pluck("code")).to include("quickbooks_nevada_address_suppressed")
  end

  it "preserves standalone married-filing-separately status" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $11.25/hr Pay method: Check Deductions: None Contributions: None Time off: None",
        tax_info: "SSN: 000-00-0001 Fed: Married Filing Separately"
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.employee_attributes.fetch(:filing_status)).to eq("married_separate")
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

  it "does not discard a percentage-based loan as a one-dollar placeholder" do
    parsed = described_class.new(
      worker: worker(pay_info: "Hourly rate: $9.25/hr Pay method: Check Deductions: Loan: 1.00% Contributions: None Time off: None"),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.payroll_fields).to contain_exactly(
      hash_including(name: "Loan", category: "loan", amount_type: "percentage", percentage: 1.to_d)
    )
    expect(parsed.warnings).to be_empty
    expect(parsed.review_items.pluck("code")).to include("obligation_terms_missing")
  end

  it "shows one obligation review item when a worker has multiple obligations" do
    parsed = described_class.new(
      worker: worker(
        pay_info: "Hourly rate: $9.25/hr Pay method: Check Deductions: Loan: $25.00 Allotment: $10.00 Contributions: None Time off: None"
      ),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.payroll_fields.pluck(:category)).to contain_exactly("loan", "allotment")
    expect(parsed.review_items.pluck("code").count("obligation_terms_missing")).to eq(1)
  end

  it "treats non-object retained snapshots as missing setup instead of crashing" do
    malformed_worker = build(
      :historical_worker,
      id: 42,
      source_name: "Worker, Alice",
      source_status: "active",
      private_snapshot: "null"
    )

    parsed = described_class.new(worker: malformed_worker, pay_frequency: "biweekly").call

    expect(parsed.errors).to include(/employee directory setup is missing/)
    expect(parsed.errors).to include(/pay setup could not be separated/)
  end

  it "turns malformed retained tax and pay sections into review errors" do
    malformed_worker = build(
      :historical_worker,
      id: 43,
      source_name: "Worker, Alice",
      source_status: "active",
      private_snapshot: JSON.generate(
        {
          "Tax info" => nil,
          "Pay info" => { "rate" => 11.25 },
          "_employee_directory" => {
            "Birth date" => "01/02/1990",
            "Email" => "worker@example.test",
            "Home address" => "123 Main Street, Hagatna, GU 96910"
          }
        }
      )
    )

    parsed = described_class.new(worker: malformed_worker, pay_frequency: "biweekly").call

    expect(parsed.errors).to include("QuickBooks tax info is malformed in the retained employee snapshot")
    expect(parsed.errors).to include("QuickBooks pay info is malformed in the retained employee snapshot")
    expect(parsed.errors).to include(/pay setup could not be separated/)
  end

  it "blocks unknown positive deductions instead of guessing their tax treatment" do
    parsed = described_class.new(
      worker: worker(pay_info: "Hourly rate: $9.25/hr Pay method: Check Deductions: Mystery: $10.00 Contributions: None Time off: None"),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.errors).to include(/needs an explicit tax\/category mapping/)
  end


  it "records an unreadable deduction label instead of raising" do
    parsed = described_class.new(
      worker: worker(pay_info: "Hourly rate: $9.25/hr Pay method: Check Deductions: : $25.00 Contributions: None Time off: None"),
      pay_frequency: "biweekly"
    ).call

    expect(parsed.errors).to include("QuickBooks deductions contain an unreadable item")
    expect(parsed.payroll_fields).to be_empty
  end
end
