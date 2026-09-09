# frozen_string_literal: true

require "rails_helper"

RSpec.describe W2GuPreflightValidator, "locked QuickBooks history" do
  let(:company) do
    create(
      :company,
      ein: "66-1234567",
      address_line1: "123 Marine Corps Drive",
      city: "Hagatna",
      state: "GU",
      zip: "96910"
    )
  end
  let(:employee) { create(:employee, company: company) }

  it "validates employees paid only through locked imported payroll" do
    create_historical_filing_source(
      company: company,
      employee: employee,
      pay_date: Date.new(2026, 3, 20),
      gross_pay: 2_000,
      federal_income_tax: 150,
      social_security_tax: 124,
      medicare_tax: 29,
      employer_social_security_tax: 124,
      employer_medicare_tax: 29
    )

    result = described_class.new(company: company, year: 2026).run

    expect(result[:blocking_count]).to eq(0)
    expect(result[:findings]).not_to include(include(code: "NO_COMMITTED_PAYROLL"))
  end

  it "returns an actionable blocker when locked history has no applied bridge" do
    source = create_historical_filing_source(
      company: company,
      employee: employee,
      pay_date: Date.new(2026, 3, 20),
      gross_pay: 2_000,
      federal_income_tax: 150,
      social_security_tax: 124,
      medicare_tax: 29,
      employer_social_security_tax: 124,
      employer_medicare_tax: 29
    )
    source.fetch(:balance).delete
    source.fetch(:bridge).delete

    result = described_class.new(company: company, year: 2026).run
    finding = result[:findings].find { |row| row[:code] == "HISTORICAL_PAYROLL_NOT_READY" }

    expect(finding).to include(severity: "blocking")
    expect(finding[:message]).to match(/applied historical YTD bridge/i)
  end
end
