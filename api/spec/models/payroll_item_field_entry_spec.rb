# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollItemFieldEntry, type: :model do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:pay_period) { create(:pay_period, company: company) }
  let(:payroll_item) { create(:payroll_item, company: company, employee: employee, pay_period: pay_period) }

  it "validates kind and tax treatment compatibility" do
    entry = described_class.new(
      payroll_item: payroll_item,
      label: "Bad Field",
      kind: "addition",
      tax_treatment: "post_tax_deduction",
      category: "other",
      amount: 10,
      source: "manual"
    )

    expect(entry).not_to be_valid
    expect(entry.errors[:tax_treatment]).to include("does not match field type")
  end

  it "allows compatible employer contribution entries" do
    entry = described_class.new(
      payroll_item: payroll_item,
      label: "Health Contribution",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "benefit",
      amount: 10,
      source: "manual",
      employee_paid: false,
      employer_paid: true
    )

    expect(entry).to be_valid
  end
end
