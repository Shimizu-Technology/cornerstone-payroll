# frozen_string_literal: true

require "rails_helper"

RSpec.describe GuamTaxCalculatorV2 do
  let!(:annual_config) do
    create(:annual_tax_config,
      tax_year: 2030,
      ss_wage_base: 184_500,
      ss_rate: 0.062,
      medicare_rate: 0.0145,
      additional_medicare_rate: 0.009,
      additional_medicare_threshold: 200_000,
      is_active: false)
  end
  let!(:filing_status_config) do
    create(:filing_status_config,
      annual_tax_config: annual_config,
      filing_status: "single",
      standard_deduction: 16_100)
  end

  before do
    create(:tax_bracket,
      filing_status_config: filing_status_config,
      bracket_order: 1,
      min_income: 0,
      max_income: nil,
      rate: 0.10)
  end

  it "normalizes married filing separately to the single-or-separate configuration" do
    calculator = described_class.new(
      tax_year: 2030,
      filing_status: "married_separate",
      pay_frequency: "biweekly"
    )

    expect(calculator.filing_status_config).to eq(filing_status_config)
  end

  it "returns the committed taxable bases and separate Additional Medicare amount" do
    calculator = described_class.new(
      tax_year: 2030,
      filing_status: "single",
      pay_frequency: "biweekly"
    )

    result = calculator.calculate(
      gross_pay: 3_000,
      reported_tips: 500,
      ytd_gross: 199_000,
      ytd_ss_taxable_wages: 184_000,
      ytd_medicare_wages: 199_000
    )

    expect(result[:social_security_taxable_wages]).to eq(500.00)
    expect(result[:social_security_taxable_tips]).to eq(0.00)
    expect(result[:medicare_taxable_wages]).to eq(3_000.00)
    expect(result[:additional_medicare_taxable_wages]).to eq(2_000.00)
    expect(result[:additional_medicare]).to eq(18.00)
  end

  it "blocks pre-2020 W-4 forms instead of silently applying modern rules" do
    expect {
      described_class.new(
        tax_year: 2030,
        filing_status: "single",
        pay_frequency: "biweekly",
        w4_form_version: 2019
      )
    }.to raise_error(ArgumentError, /Pre-2020 Form W-4/)
  end
end
