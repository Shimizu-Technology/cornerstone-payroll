# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe PayStubGenerator do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, name: "Stub Company") }
  let(:pay_period) { create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 4, 15)) }
  let(:employee) do
    create(
      :employee,
      company: company,
      first_name: "Pat",
      last_name: "Stub",
      employment_type: "hourly",
      pay_rate: 20
    )
  end

  let(:payroll_item) do
    create(
      :payroll_item,
      pay_period: pay_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      bonus: 50,
      reported_tips: 25,
      custom_earnings: [ { "label" => "Chief Stipend", "amount" => 75 } ],
      custom_deductions: [ { "label" => "Cash Advance", "amount" => 40 } ],
      gross_pay: 310,
      net_pay: 250,
      ytd_gross: 310,
      ytd_net: 250
    )
  end

  it "prints supplemental earnings even when stored earning rows are partial" do
    payroll_item.payroll_item_earnings.create!(
      category: "regular",
      label: "Regular Pay",
      hours: 8,
      rate: 20,
      amount: 160
    )

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Regular Pay")
    expect(text).to include("Bonus")
    expect(text).to include("Reported Tips")
    expect(text).to include("Chief Stipend")
  end

  it "prints legacy insurance and loan YTD values when those rows are visible" do
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    create(
      :payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      insurance_payment: 30,
      loan_payment: 15,
      gross_pay: 160,
      net_pay: 115,
      total_deductions: 45
    )
    payroll_item.update!(insurance_payment: 10, loan_payment: 5, total_deductions: payroll_item.total_deductions.to_f + 15)

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Health Insurance")
    expect(text).to include("Loan Repayment")
    expect(text).to include("$40.00")
    expect(text).to include("$20.00")
  end

  it "prints legacy itemized deductions and includes them in YTD total deductions" do
    deduction_type = DeductionType.create!(
      company: company,
      name: "Garnishment",
      category: "post_tax",
      sub_category: "garnishment"
    )
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    prior_item = create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8)
    prior_item.payroll_item_deductions.create!(
      deduction_type: deduction_type,
      label: "Garnishment",
      category: "post_tax",
      amount: 12
    )
    payroll_item.payroll_item_deductions.create!(
      deduction_type: deduction_type,
      label: "Garnishment",
      category: "post_tax",
      amount: 8
    )
    payroll_item.update!(custom_deductions: [])

    generator = described_class.new(payroll_item)
    text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

    expect(text).to include("Garnishment")
    expect(text).to include("$20.00")
    expect(generator.send(:ytd_total_deductions)).to eq(20.0)
  end

  it "prints custom deductions by label" do
    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Cash Advance")
  end

  it "prints treatment-aware payroll adjustments by label without duplicating non-taxable earnings" do
    payroll_item.update!(
      payroll_adjustments: [
        { "label" => "Taxable Bonus", "amount" => 100.0, "treatment" => "taxable_addition", "active" => true },
        { "label" => "Reimbursement", "amount" => 25.0, "treatment" => "non_taxable_addition", "active" => true },
        { "label" => "Pre-Tax Deduction", "amount" => 10.0, "treatment" => "pre_tax_deduction", "active" => true },
        { "label" => "Post-Tax Deduction", "amount" => 15.0, "treatment" => "post_tax_deduction", "active" => true }
      ]
    )
    payroll_item.payroll_item_earnings.create!(category: "non_taxable", label: "Reimbursement", amount: 25.0)

    pdf = described_class.new(payroll_item).generate
    text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

    expect(text).to include("Taxable Bonus")
    expect(text).to include("NON-TAXABLE ADDITIONS")
    expect(text.scan("Reimbursement").count).to eq(1)
    expect(text).to include("Pre-Tax Deduction")
    expect(text).to include("Post-Tax Deduction")
  end

  it "prints total employer contribution YTD on pay stubs" do
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Employer Health",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "insurance"
    )
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    prior_item = create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8)
    prior_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Employer Health",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "insurance",
      amount: 15,
      source: "manual",
      employee_paid: false,
      employer_paid: true
    )
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Employer Health",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "insurance",
      amount: 10,
      source: "manual",
      employee_paid: false,
      employer_paid: true
    )

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("TOTAL EMPLOYER CONTRIBUTIONS")
    expect(text).to include("$25.00")
  end

  it "uses stored tax and retirement YTD snapshots in total deductions YTD" do
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      withholding_tax: 999,
      social_security_tax: 999,
      medicare_tax: 999,
      retirement_payment: 999,
      roth_retirement_payment: 999)
    payroll_item.update!(
      ytd_withholding_tax: 10,
      ytd_social_security_tax: 20,
      ytd_medicare_tax: 5,
      ytd_retirement: 30,
      ytd_roth_retirement: 7,
      custom_deductions: []
    )

    expect(described_class.new(payroll_item).send(:ytd_total_deductions)).to eq(72.0)
  end

  it "does not include unrelated cross-tuple payroll field history in YTD deduction totals" do
    prior_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 3, 15))
    prior_item = create(:payroll_item,
      pay_period: prior_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8)
    prior_item.payroll_item_field_entries.create!(
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "pre_tax_deduction",
      category: "insurance",
      amount: 999,
      source: "manual"
    )
    payroll_item.payroll_item_field_entries.create!(
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount: 20,
      source: "manual"
    )
    payroll_item.payroll_item_field_entries.create!(
      label: "Uniform",
      kind: "deduction",
      tax_treatment: "pre_tax_deduction",
      category: "insurance",
      amount: 5,
      source: "manual"
    )

    generator = described_class.new(payroll_item)

    expect(generator.send(:ytd_payroll_field_deductions_total)).to eq(25.0)
  end

  it "limits payroll field YTD values to the current calendar year" do
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent"
    )
    prior_year_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2025, 12, 31))
    prior_year_item = create(:payroll_item,
      pay_period: prior_year_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8)
    prior_year_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount: 80,
      source: "manual"
    )
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount: 20,
      source: "manual"
    )

    entry = payroll_item.payroll_item_field_entries.find { |candidate| candidate.label == "Rent Deduction" }
    generator = described_class.new(payroll_item)

    expect(generator.send(:ytd_payroll_field_amount, entry)).to eq(20.0)
  end

  it "does not include later same-pay-date custom deductions in YTD custom deduction totals" do
    later_period = create(
      :pay_period,
      :committed,
      company: company,
      pay_date: pay_period.pay_date
    )
    create(
      :payroll_item,
      pay_period: later_period,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 8,
      custom_deductions: [ { "label" => "Cash Advance", "amount" => 60 } ],
      total_deductions: 60,
      gross_pay: 160,
      net_pay: 100
    )

    text = PDF::Reader.new(StringIO.new(described_class.new(payroll_item).generate)).pages.map(&:text).join("\n")

    expect(text).to include("Cash Advance")
    expect(text).to include("$40.00")
    expect(text).not_to include("$100.00")
  end

  it "keeps a standard earnings statement to one page" do
    payroll_item.payroll_item_earnings.create!(
      category: "regular",
      label: "Regular Pay",
      hours: 8,
      rate: 20,
      amount: 160
    )

    pdf = described_class.new(payroll_item).generate

    expect(PDF::Reader.new(StringIO.new(pdf)).page_count).to eq(1)
  end

  it "prints the generated timestamp in Guam time" do
    travel_to Time.utc(2026, 4, 29, 19, 48) do
      pdf = described_class.new(payroll_item).generate
      text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

      expect(text).to include("Generated on April 30, 2026 at 05:48 AM ChST")
    end
  end

  it "lets dense earnings statements flow to additional content pages without a footer-only page" do
    120.times do |index|
      payroll_item.payroll_item_earnings.create!(
        category: "other",
        label: "Supplemental Earning #{index + 1}",
        amount: 10 + index
      )
    end

    pdf = described_class.new(payroll_item).generate
    pages = PDF::Reader.new(StringIO.new(pdf)).pages

    expect(pages.count).to be > 1
    expect(pages.last.text).to include("Supplemental Earning 120")
    expect(pages.last.text).to include("Generated on")
  end
end
