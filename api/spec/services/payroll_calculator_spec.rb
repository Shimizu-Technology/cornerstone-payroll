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
      allow(relation).to receive(:find_by).with(name: label, category: "employer_contribution").and_return(nil, existing)
      allow(relation).to receive(:find_by).with(name: label, category: "pre_tax", sub_category: "retirement").and_return(nil)
      allow(relation).to receive(:create!)
        .with(name: label, category: "employer_contribution", sub_category: "retirement")
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key value"))

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

    it "does not mutate a same-name deduction type that is already assigned to employees" do
      calculator = described_class.new(employee, payroll_item)
      conflicting = DeductionType.create!(
        company: company,
        name: "401(k) Employer Match",
        category: "pre_tax",
        sub_category: "retirement",
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: conflicting,
        amount: 10.00,
        is_percentage: false,
        active: true
      )

      expect {
        calculator.send(:find_or_create_employer_deduction_type, conflicting.name)
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(conflicting.reload.category).to eq("pre_tax")
    end
  end

  describe "#calculate" do
    let(:employee) do
      create(
        :employee,
        company: company,
        department: department,
        pay_rate: 10.0,
        additional_withholding: 15.0
      )
    end

    let(:payroll_item) do
      create(
        :payroll_item,
        employee: employee,
        pay_period: pay_period,
        pay_rate: 10.0,
        hours_worked: 100,
        overtime_hours: 0,
        holiday_hours: 0,
        pto_hours: 0,
        reported_tips: 0,
        bonus: 0
      )
    end

    it "applies a one-time FIT adjustment on top of the normal W-4 calculation" do
      calculator = described_class.for(employee, payroll_item)

      calculator.calculate
      base_fit = payroll_item.withholding_tax

      payroll_item.withholding_tax_adjustment = -15.0
      calculator.calculate

      expect(payroll_item.withholding_tax).to eq(base_fit - 15.0)
    end

    it "floors adjusted FIT at zero when the adjustment would make it negative" do
      payroll_item.withholding_tax_adjustment = -10_000

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.withholding_tax).to eq(0)
    end

    it "still honors a final FIT override when one is provided" do
      payroll_item.withholding_tax_adjustment = -15.0
      payroll_item.withholding_tax_override = 12.34

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.withholding_tax).to eq(12.34)
    end

    it "lets a payroll item override the employee's W-4 Step 4(c) amount for one pay period" do
      payroll_item.additional_withholding_override = 0

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.additional_withholding).to eq(0)
    end

    it "does not let extra W-4 withholding create a negative normal paycheck" do
      employee.update!(additional_withholding: 66.0)
      payroll_item.update!(
        hours_worked: 0,
        overtime_hours: 0,
        holiday_hours: 0,
        pto_hours: 0,
        bonus: 0,
        reported_tips: 0,
        custom_earnings: []
      )

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.gross_pay).to eq(0.0)
      expect(payroll_item.additional_withholding).to eq(0.0)
      expect(payroll_item.total_deductions).to eq(0.0)
      expect(payroll_item.net_pay).to eq(0.0)
    end

    it "reapplies W-4 extra withholding when hours arrive after a zero-pay calculation" do
      employee.update!(additional_withholding: 66.0)
      payroll_item.update!(
        hours_worked: 0,
        overtime_hours: 0,
        holiday_hours: 0,
        pto_hours: 0,
        bonus: 0,
        reported_tips: 0,
        custom_earnings: []
      )

      described_class.for(employee, payroll_item).calculate
      payroll_item.save!
      expect(payroll_item.reload.additional_withholding).to eq(0.0)

      payroll_item.update!(hours_worked: 10)
      described_class.for(employee.reload, payroll_item.reload).calculate

      expect(payroll_item.additional_withholding).to eq(66.0)
      expect(payroll_item.total_deductions).to be >= 66.0
      expect(payroll_item.net_pay).to be >= 0.0
    end

    it "caps remaining deductions so total deductions reconcile with zero net pay" do
      payroll_item.update!(
        hours_worked: 1,
        overtime_hours: 0,
        holiday_hours: 0,
        pto_hours: 0,
        bonus: 0,
        reported_tips: 0,
        withholding_tax_override: 250.0,
        custom_deductions: [
          { "label" => "Cash Advance", "amount" => 75.0 }
        ]
      )

      described_class.for(employee, payroll_item).calculate

      available_pay = payroll_item.gross_pay.to_f + payroll_item.non_taxable_pay.to_f
      expect(payroll_item.total_deductions).to eq(available_pay)
      expect(payroll_item.net_pay).to eq(0.0)
      expect(payroll_item.gross_pay - payroll_item.total_deductions + payroll_item.non_taxable_pay.to_f).to eq(0.0)
      expect(payroll_item.custom_deductions_total).to eq(0.0)
      expect(payroll_item.withholding_tax).to be <= available_pay
    end

    it "removes itemized deduction rows that are capped to zero on recalculation" do
      employee.update!(additional_withholding: 0)
      deduction_type = DeductionType.create!(
        company: company,
        name: "Cash Advance",
        category: "post_tax",
        sub_category: "other",
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: deduction_type,
        amount: 75.0,
        is_percentage: false,
        active: true
      )
      payroll_item.update!(
        hours_worked: 1,
        overtime_hours: 0,
        holiday_hours: 0,
        pto_hours: 0,
        bonus: 0,
        reported_tips: 0,
        withholding_tax_override: 100.0,
        custom_deductions: []
      )

      payroll_item.calculate!
      expect(payroll_item.reload.payroll_item_deductions).to be_empty
      expect(payroll_item.loan_payment).to eq(0.0)
      expect(payroll_item.insurance_payment).to eq(0.0)

      payroll_item.calculate!
      expect(payroll_item.reload.payroll_item_deductions).to be_empty
      expect(payroll_item.loan_payment).to eq(0.0)
      expect(payroll_item.insurance_payment).to eq(0.0)
    end

    it "zeros loan and insurance mirrors when capped itemized deductions are removed" do
      employee.update!(additional_withholding: 0)
      loan_type = DeductionType.create!(
        company: company,
        name: "Employee Loan",
        category: "post_tax",
        sub_category: "loan",
        active: true
      )
      insurance_type = DeductionType.create!(
        company: company,
        name: "Medical Insurance",
        category: "post_tax",
        sub_category: "insurance",
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: loan_type,
        amount: 75.0,
        is_percentage: false,
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: insurance_type,
        amount: 75.0,
        is_percentage: false,
        active: true
      )
      payroll_item.update!(
        hours_worked: 1,
        overtime_hours: 0,
        holiday_hours: 0,
        pto_hours: 0,
        bonus: 0,
        reported_tips: 0,
        withholding_tax_override: 250.0,
        custom_deductions: []
      )

      payroll_item.calculate!

      expect(payroll_item.reload.payroll_item_deductions).to be_empty
      expect(payroll_item.loan_payment).to eq(0.0)
      expect(payroll_item.insurance_payment).to eq(0.0)
      expect(payroll_item.total_deductions).to eq(payroll_item.gross_pay)
      expect(payroll_item.net_pay).to eq(0.0)
    end

    it "treats tips paid out as a deduction that reduces net pay only" do
      payroll_item.tips_paid_out = 50.0

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.gross_pay).to eq(1000.0)
      expect(payroll_item.total_deductions).to eq(
        payroll_item.withholding_tax +
        payroll_item.additional_withholding +
        payroll_item.social_security_tax +
        payroll_item.medicare_tax +
        50.0
      )
      expect(payroll_item.net_pay).to eq(payroll_item.gross_pay - payroll_item.total_deductions)
    end

    it "treats custom deductions as post-tax check reductions" do
      payroll_item.custom_deductions = [
        { "label" => "Cash Advance", "amount" => 75.0 }
      ]

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.gross_pay).to eq(1000.0)
      expect(payroll_item.total_deductions).to eq(
        payroll_item.withholding_tax +
        payroll_item.additional_withholding +
        payroll_item.social_security_tax +
        payroll_item.medicare_tax +
        75.0
      )
      expect(payroll_item.net_pay).to eq(payroll_item.gross_pay - payroll_item.total_deductions)
    end
  end
end
