# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollTaxSummary do
  it "reconciles an actual threshold-crossing calculation including additional W-4 withholding" do
    company = create(:company)
    employee = create(:employee, company:, additional_withholding: 25)
    config = create(:annual_tax_config, tax_year: 2030, ss_wage_base: 184_500,
      medicare_rate: 0.0145, additional_medicare_rate: 0.009, additional_medicare_threshold: 200_000)
    filing = create(:filing_status_config, annual_tax_config: config, filing_status: "single", standard_deduction: 0)
    create(:tax_bracket, filing_status_config: filing, bracket_order: 1, min_income: 0, max_income: nil, rate: 0.10)
    previous = create(:pay_period, :committed, company:, start_date: "2030-01-01", end_date: "2030-01-14", pay_date: "2030-01-18")
    create(:payroll_item, pay_period: previous, employee:, gross_pay: 199_500,
      medicare_taxable_wages: 199_500, social_security_taxable_wages: 184_500,
      social_security_tax: 11_439, medicare_tax: 2_892.75)
    period = create(:pay_period, company:, start_date: "2030-01-15", end_date: "2030-01-28", pay_date: "2030-02-01")
    item = build(:payroll_item, company:, employee:, pay_period: period, hours_worked: 1, pay_rate: 1_000)

    PayrollCalculator.for(employee, item).calculate

    expect(item.gross_pay).to eq(1_000.to_d)
    expect(item.medicare_tax).to eq(19.to_d) # $14.50 base plus $4.50 on the $500 crossing the threshold
    expect(item.additional_medicare_tax).to eq(4.50.to_d)
    expect(item.employer_medicare_tax).to eq(14.50.to_d)
    expect(item.additional_withholding).to eq(25.to_d)
    summary = described_class.new(item)
    expect(summary.total).to eq(item.total_deductions)
    expect(summary.lines.sum { |line| line[:amount].to_d }).to eq(summary.total)
    expect(summary.total).to eq(item.gross_pay - item.net_pay)
  end
end
