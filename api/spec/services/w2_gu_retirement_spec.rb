# frozen_string_literal: true

require "rails_helper"

RSpec.describe W2GuAggregator, "fixed and flexible retirement" do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:period) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2025, 7, 1), end_date: Date.new(2025, 7, 14), pay_date: Date.new(2025, 7, 18))
  end
  let(:item) { create(:payroll_item, employee: employee, pay_period: period, gross_pay: 10_000, retirement_payment: 20, roth_retirement_payment: 10) }

  def add_deduction(item:, label:, amount:, category:, group:)
    type = company.deduction_types.find_or_create_by!(name: label) do |deduction|
      deduction.category = category
      deduction.sub_category = "retirement"
      deduction.reporting_group = group
    end
    item.payroll_item_deductions.create!(deduction_type: type, label: label, amount: amount, category: category, reporting_group: group)
  end

  before do
    add_deduction(item: item, label: "Fixed 401(k)", amount: 900.00, category: "pre_tax", group: "401k_pre_tax")
    add_deduction(item: item, label: "Roth 401(k)", amount: 100, category: "post_tax", group: "401k_after_tax")
    add_deduction(item: item, label: "Employer 401(k)", amount: 200, category: "employer_contribution", group: "401k_pre_tax")
    field = create(:payroll_field_definition, company: company, name: "Extra 401(k)", kind: "deduction",
      tax_treatment: "pre_tax_deduction", category: "retirement", reporting_group: "401k_pre_tax")
    create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: field, amount: 25, reporting_group: "401k_pre_tax")
    add_deduction(item: item, label: "Extra 401(k)", amount: 25, category: "pre_tax", group: "401k_pre_tax").deduction_type.update!(name: "Payroll Field: Extra 401(k)")
  end

  it "reports fixed, flexible and built-in employee contributions once without reducing FICA wages" do
    report = described_class.new(company, 2025, include_historical: false).generate
    row = report.fetch(:employees).sole
    expect(row).to include(box1_wages_tips_other_comp: 9055.00, box5_medicare_wages_tips: 10_000, box13_retirement_plan: true)
    expect(row.fetch(:box12)).to include(include(code: "D", amount: 945.00), include(code: "AA", amount: 110.0))
    expect(report.fetch(:totals)).to include(box12_code_d_total: 945.00, box12_code_aa_total: 110.0)
  end

  it "adds the historical bridge exactly once and does not alter saved paycheck snapshots" do
    source = create_historical_filing_source(company: company, employee: employee, pay_date: Date.new(2025, 3, 20),
      gross_pay: 2000, retirement: 500, roth_retirement: 200, federal_income_tax: 100, social_security_tax: 124,
      medicare_tax: 29, employer_social_security_tax: 124, employer_medicare_tax: 29)
    snapshot = item.reload.attributes
    row = described_class.new(company, 2025, include_historical: true).generate.fetch(:employees).sole
    expect(row).to include(box1_wages_tips_other_comp: 10555.00, box5_medicare_wages_tips: 12_000)
    expect(row.fetch(:box12)).to include(include(code: "D", amount: 1445.00), include(code: "AA", amount: 310.0))
    expect(row.fetch(:source_summary)).to include(cornerstone_payroll_item_count: 1, quickbooks_bridge_balance_count: 1)
    expect(item.reload.attributes).to eq(snapshot)
    expect(source.fetch(:balance).reload.retirement).to eq(500.to_d)
  end

  it "uses the same exclusions for retirement and wage totals" do
    item.update_columns(voided: true)
    expect(described_class.new(company, 2025, include_historical: false).generate.fetch(:totals)).to include(box12_code_d_total: 0, box12_code_aa_total: 0)
    item.update_columns(voided: false, employment_type: "contractor")
    expect(described_class.new(company, 2025, include_historical: false).generate.fetch(:employees)).to be_empty
    item.update_columns(employment_type: "salary")
    period.update_columns(correction_status: "voided")
    expect(described_class.new(company, 2025, include_historical: false).generate.fetch(:employees)).to be_empty
    period.update_columns(correction_status: nil, status: "draft")
    expect(described_class.new(company, 2025, include_historical: false).generate.fetch(:employees)).to be_empty
    period.update_columns(status: "committed", pay_date: Date.new(2024, 7, 18))
    expect(described_class.new(company, 2025, include_historical: false).generate.fetch(:employees)).to be_empty
    other_company = create(:company)
    expect(described_class.new(other_company, 2024, include_historical: false).generate.fetch(:employees)).to be_empty
  end
end
