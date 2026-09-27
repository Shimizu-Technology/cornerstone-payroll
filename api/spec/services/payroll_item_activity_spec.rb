# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollItemActivity do
  let(:company) { create(:company) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:employee) { create(:employee, company: company) }
  let(:item) do
    create(:payroll_item, company: company, pay_period: period, employee: employee, hours_worked: 0)
  end

  it "identifies a clean zero row" do
    expect(described_class.classify(item)).to eq(:verified_empty)
  end

  it "retains a real paycheck whose deductions reduce net to zero" do
    item.update!(gross_pay: 100, total_deductions: 100, net_pay: 0)
    expect(described_class.classify(item)).to eq(:active)
  end

  it "flags worked time and deduction-only data for review" do
    item.update!(hours_worked: 5, loan_deduction: 10)
    expect(described_class.classify(item)).to eq(:review)
    expect(described_class.reasons(item)[:review]).to include("hours_worked", "loan_deduction")
  end

  it "flags zero-amount source linkage for review" do
    item.update!(import_source: "legacy_import")
    expect(described_class.classify(item)).to eq(:review)
  end

  it "retains zero-net tip reporting as payroll activity" do
    item.update!(reported_tips: 20, net_pay: 0)
    expect(described_class.classify(item)).to eq(:active)
  end

  it "retains employer-only benefits as activity" do
    item.payroll_item_field_entries.create!(
      label: "Employer benefit", kind: "employer_contribution",
      tax_treatment: "employer_contribution", category: "benefit",
      source: "manual", amount: 25, active: true
    )
    expect(described_class.classify(item)).to eq(:active)
  end

  it "batch classifies clean and linked zero rows consistently" do
    linked_employee = create(:employee, company: company)
    linked = create(:payroll_item, company: company, pay_period: period, employee: linked_employee, hours_worked: 0)
    linked.update!(import_source: "import")

    result = described_class.classify_many([ item, linked ])

    expect(result).to eq(item => :verified_empty, linked => :review)
  end
end
