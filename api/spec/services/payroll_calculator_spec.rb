# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollCalculator do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let(:pay_period) { create(:pay_period, company: company, pay_date: Date.new(2024, 1, 19)) }
  let(:payroll_item) { create(:payroll_item, employee: employee, pay_period: pay_period) }

  describe "#find_or_create_employer_deduction_type" do
    it "reloads the existing deduction type when a concurrent create collides" do
      calculator = described_class.new(employee, payroll_item)
      label = "401(k) Employer Match"
      existing = DeductionType.create!(
        company: company,
        name: label,
        category: "employer_contribution",
        sub_category: "retirement",
        active: true
      )

      relation = company.deduction_types
      allow(payroll_item).to receive(:company).and_return(company)
      allow(company).to receive(:deduction_types).and_return(relation)
      allow(relation).to receive(:find_by).with(name: label).and_return(nil)
      allow(relation).to receive(:create!)
        .with(name: label, category: "employer_contribution", sub_category: "retirement")
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key value"))
      allow(relation).to receive(:find_by!).with(name: label).and_return(existing)

      result = calculator.send(:find_or_create_employer_deduction_type, label)

      expect(result).to eq(existing)
    end

    it "repairs a legacy pre-tax employer match deduction type" do
      calculator = described_class.new(employee, payroll_item)
      legacy = DeductionType.create!(
        company: company,
        name: "Roth 401(k) Employer Match",
        category: "pre_tax",
        sub_category: "retirement",
        active: true
      )

      result = calculator.send(:find_or_create_employer_deduction_type, legacy.name)

      expect(result.reload.category).to eq("employer_contribution")
    end
  end
end
