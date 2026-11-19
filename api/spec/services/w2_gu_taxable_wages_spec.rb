# frozen_string_literal: true

require "rails_helper"

RSpec.describe W2GuAggregator, "year-end taxable wages" do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:period) { create(:pay_period, :committed, company: company, start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 15)) }

  def item_for(worker = employee, **values)
    create(:payroll_item, company: company, employee: worker, pay_period: period, **values)
  end

  def health_deduction(item, amount)
    type = company.deduction_types.create!(name: "Section 125 health", category: "pre_tax", sub_category: "insurance")
    item.payroll_item_deductions.create!(deduction_type: type, label: type.name, category: "pre_tax", amount: amount)
  end

  def row
    described_class.new(company, 2026).generate[:employees].sole
  end

  it "excludes Section 125 from Boxes 1/3/5, 401(k) from Box 1 only, and retains Roth and tips" do
    item = item_for(gross_pay: 1200, reported_tips: 200, cash_tips_reported: 200,
      retirement_payment: 100, roth_retirement_payment: 50, non_taxable_pay: 75,
      fit_taxable_wages: 1000, social_security_taxable_wages: 1000,
      social_security_taxable_tips: 200, medicare_taxable_wages: 1200)
    health_deduction(item, 100)
    snapshot = item.reload.attributes
    expect(row).to include(box1_wages_tips_other_comp: 1000, box3_social_security_wages: 900,
      box5_medicare_wages_tips: 1100, box7_social_security_tips: 200, non_taxable_total: 75)
    expect(item.reload.attributes).to eq(snapshot)
    expect(row).to include(fica_withheld_on_section_125: true)
    expect(described_class.new(company, 2026).generate[:compliance_issues].join).to include("941-X")
    expect(W2GuWageImpact.new(company, 2026).generate).to eq(
      box1: [ 1100, 1000, -100 ], box3: [ 1000, 900, -100 ], box5: [ 1200, 1100, -100 ])
  end

  it "uses saved components when FIT and FICA bases are null without subtracting live reimbursements twice" do
    item = item_for(gross_pay: 1000, non_taxable_pay: 100, retirement_payment: 50, roth_retirement_payment: 25)
    health_deduction(item, 100)
    expect(row).to include(box1_wages_tips_other_comp: 850, box3_social_security_wages: 900,
      box5_medicare_wages_tips: 900, missing_committed_tax_bases: true)
  end

  it "counts a flexible health field and its itemized mirror once, including saved pre-tax adjustments" do
    item = item_for(gross_pay: 1000, payroll_adjustments: [ { label: "Section 125 dental", amount: 25, treatment: "pre_tax_deduction" } ])
    field = create(:payroll_field_definition, company: company, name: "Section 125 health", kind: "deduction",
      tax_treatment: "pre_tax_deduction", category: "benefit")
    create(:payroll_item_field_entry, payroll_item: item, payroll_field_definition: field, amount: 100)
    type = company.deduction_types.create!(name: "Payroll Field: Section 125 health", category: "pre_tax", sub_category: "insurance")
    item.payroll_item_deductions.create!(deduction_type: type, label: field.name, category: "pre_tax", amount: 100)
    expect(row).to include(box1_wages_tips_other_comp: 875, box3_social_security_wages: 875, box5_medicare_wages_tips: 875)
  end

  it "preserves signed wage, tip and benefit corrections in annual totals" do
    original = item_for(gross_pay: 1200, reported_tips: 200, cash_tips_reported: 200)
    health_deduction(original, 100)
    correction_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 11, 30))
    correction = create(:payroll_item, company: company, employee: employee, pay_period: correction_period)
    correction.update_columns(gross_pay: -120, reported_tips: -20, cash_tips_reported: -20,
      fit_taxable_wages: -110, social_security_taxable_wages: -100, social_security_taxable_tips: -20, medicare_taxable_wages: -120)
    correction.payroll_item_deductions.create!(deduction_type: original.payroll_item_deductions.sole.deduction_type,
      label: "Section 125 health", category: "pre_tax", amount: -10)
    expect(row).to include(box1_wages_tips_other_comp: 990, box3_social_security_wages: 810,
      box5_medicare_wages_tips: 990, box7_social_security_tips: 180)
  end

  it "does not flag FICA on benefits when the paycheck already excluded them" do
    item = item_for(gross_pay: 1000, fit_taxable_wages: 900, social_security_taxable_wages: 900,
      social_security_taxable_tips: 0, medicare_taxable_wages: 900)
    health_deduction(item, 100)
    expect(row).to include(box3_social_security_wages: 900, box5_medicare_wages_tips: 900, fica_withheld_on_section_125: false)
  end

  it "reduces Box 1 only for a non-401(k) pre-tax retirement deferral, without a 941-X flag" do
    item = item_for(gross_pay: 1000, fit_taxable_wages: 900, social_security_taxable_wages: 1000,
      social_security_taxable_tips: 0, medicare_taxable_wages: 1000)
    type = company.deduction_types.create!(name: "457(b) Deferred Comp", category: "pre_tax", sub_category: "retirement")
    item.payroll_item_deductions.create!(deduction_type: type, label: type.name, category: "pre_tax", amount: 100)
    expect(row).to include(box1_wages_tips_other_comp: 900, box3_social_security_wages: 1000,
      box5_medicare_wages_tips: 1000, fica_withheld_on_section_125: false)
  end

  it "treats an unlabeled pre-tax adjustment as FICA-taxable" do
    item_for(gross_pay: 1000, fit_taxable_wages: 900, social_security_taxable_wages: 1000,
      social_security_taxable_tips: 0, medicare_taxable_wages: 1000,
      payroll_adjustments: [ { label: "401(k) catch-up", amount: 100, treatment: "pre_tax_deduction" } ])
    expect(row).to include(box1_wages_tips_other_comp: 900, box3_social_security_wages: 1000,
      box5_medicare_wages_tips: 1000, fica_withheld_on_section_125: false)
  end

  it "rejects inconsistent saved FIT wages without changing the paid payroll" do
    item = item_for(gross_pay: 1000, fit_taxable_wages: 700)
    expect(row).to include(box1_wages_tips_other_comp: 1000, inconsistent_fit_taxable_wages: true)
    expect(item.reload.fit_taxable_wages).to eq(700)
  end

  it "reproduces AIRE's aggregate gap from contractor zero bases, not W-4 adjustments or deductions" do
    create(:information_return_threshold, tax_year: 2026, threshold_amount: 2000)
    contractor = create(:employee, :contractor, company: company)
    item_for(gross_pay: 1200, fit_taxable_wages: 1200, social_security_taxable_wages: 1200,
      social_security_taxable_tips: 0, medicare_taxable_wages: 1200)
    item_for(contractor, employment_type: "contractor", gross_pay: 400, fit_taxable_wages: 0,
      social_security_taxable_wages: 0, social_security_taxable_tips: 0, medicare_taxable_wages: 0)
    expect(period.payroll_items.sum(:fit_taxable_wages)).to eq(1200)
    expect(period.payroll_items.sum(:gross_pay)).to eq(1600)
    expect(row).to include(employee_id: employee.id, box1_wages_tips_other_comp: 1200,
      box3_social_security_wages: 1200, box5_medicare_wages_tips: 1200)
    expect(Form1099NecAggregator.new(company, 2026).generate[:all_contractors].sole).to include(total_compensation: 400)
  end

  it "combines inclusive historical gross with exclusive live gross and applies the SS cap after benefits" do
    source = create_historical_filing_source(company: company, employee: employee, pay_date: Date.new(2026, 8, 27),
      gross_pay: 185_000, retirement: 5000, non_taxable_pay: 1000,
      federal_income_tax: 0, social_security_tax: 0, medicare_tax: 0,
      employer_social_security_tax: 0, employer_medicare_tax: 0,
      social_security_taxable_wages: 182_000, medicare_taxable_wages: 182_000)
    source[:balance].update_columns(pretax_deductions: 7000, fit_taxable_wages: 177_000)
    item = item_for(gross_pay: 5000, reported_tips: 1000, cash_tips_reported: 1000, retirement_payment: 200)
    health_deduction(item, 500)
    expect(row).to include(box1_wages_tips_other_comp: 181_300, box3_social_security_wages: 184_500,
      box5_medicare_wages_tips: 186_500, box7_social_security_tips: 0)
  end

  it "rebuilds all live SS allocations when benefits restore wage-base room in a later paycheck" do
    item = item_for(gross_pay: 184_000, social_security_taxable_wages: 184_000)
    health_deduction(item, 1000)
    next_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 11, 30))
    create(:payroll_item, company: company, employee: employee, pay_period: next_period,
      gross_pay: 3000, social_security_taxable_wages: 500, social_security_taxable_tips: 0)
    expect(row).to include(box3_social_security_wages: 184_500, box5_medicare_wages_tips: 186_000)
  end
end
