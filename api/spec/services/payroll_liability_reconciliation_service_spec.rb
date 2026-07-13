# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollLiabilityReconciliationService do
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }

  it "marks an existing committed period without postings as legacy unposted" do
    period = create(:pay_period, :committed, company: company)
    create(:payroll_item, pay_period: period, employee: employee, company: company, withholding_tax: 10)

    result = described_class.new(pay_period: period).call

    expect(result).to include(
      status: "legacy_unposted",
      historical_backfill_required: true,
      net_liability: 0.0
    )
  end

  it "returns category and authority totals for a posted period" do
    period = create(:pay_period, :committed, company: company)
    create(:payroll_item,
      pay_period: period,
      employee: employee,
      company: company,
      withholding_tax: 10,
      social_security_tax: 20,
      employer_social_security_tax: 20)
    PayrollLiabilityPostingService.post!(pay_period: period)

    result = described_class.new(pay_period: period).call

    expect(result[:status]).to eq("posted")
    expect(result[:net_liability]).to eq(50.0)
    expect(result[:totals_by_category]).to include(
      "guam_income_tax_withheld" => 10.0,
      "social_security_employee" => 20.0,
      "social_security_employer" => 20.0
    )
  end

  it "surfaces unclassified legacy deductions instead of treating them as paid or classified" do
    period = create(:pay_period, :committed, company: company)
    create(:payroll_item,
      pay_period: period,
      employee: employee,
      company: company,
      withholding_tax: 10,
      custom_deductions: [ { "label" => "Court order", "amount" => 25 } ])
    PayrollLiabilityPostingService.post!(pay_period: period)

    result = described_class.new(pay_period: period).call

    expect(result[:status]).to eq("attention_required")
    expect(result[:unclassified_components]).to contain_exactly(include(
      source: "custom_deduction",
      label: "Court order",
      amount: 25.0
    ))
  end
end
