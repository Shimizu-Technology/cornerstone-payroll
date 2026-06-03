# frozen_string_literal: true

require "rails_helper"

RSpec.describe DeductionsContributionsReportPdfGenerator do
  describe "post-tax deduction label collisions" do
    it "combines structured and custom deductions with the same label in the displayed row total" do
      company = create(:company)
      employee = create(:employee, company: company)
      pay_period = create(:pay_period, :committed, company: company)
      deduction_type = DeductionType.create!(
        company: company,
        name: "Cash Advance",
        category: "post_tax",
        sub_category: "other"
      )
      payroll_item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        company: company,
        custom_deductions: [ { "label" => "Cash Advance", "amount" => 20.00 } ]
      )
      PayrollItemDeduction.create!(
        payroll_item: payroll_item,
        deduction_type: deduction_type,
        label: "Cash Advance",
        category: "post_tax",
        amount: 10.00
      )

      amount = described_class.new(pay_period).send(
        :deduction_amount_for_label,
        payroll_item,
        "Cash Advance",
        "post_tax"
      )

      expect(amount).to eq(30.00)
    end

    it "includes custom-only deductions in employee deduction totals" do
      company = create(:company)
      employee = create(:employee, company: company)
      pay_period = create(:pay_period, :committed, company: company)
      payroll_item = create(
        :payroll_item,
        pay_period: pay_period,
        employee: employee,
        company: company,
        custom_deductions: [ { "label" => "Cash Advance", "amount" => 20.00 } ]
      )

      expect(described_class.new(pay_period).send(:employee_deductions_total, payroll_item)).to eq(20.00)
    end

    it "includes field-only employee deductions in totals" do
      company = create(:company)
      employee = create(:employee, company: company)
      pay_period = create(:pay_period, :committed, company: company)
      payroll_item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company)
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent"
      )
      payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent",
        amount: 75.00,
        source: "manual"
      )

      generator = described_class.new(pay_period)

      expect(generator.send(:deduction_amount_for_label, payroll_item, "Rent Deduction", "post_tax")).to eq(75.00)
      expect(generator.send(:employee_deductions_total, payroll_item)).to eq(75.00)
    end

    it "does not drop non-field deductions that coincidentally match a field label and amount" do
      company = create(:company)
      employee = create(:employee, company: company)
      pay_period = create(:pay_period, :committed, company: company)
      deduction_type = DeductionType.create!(company: company, name: "Manual Rent", category: "post_tax", sub_category: "rent")
      payroll_item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company)
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent"
      )
      payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent",
        amount: 75.00,
        source: "manual"
      )
      PayrollItemDeduction.create!(
        payroll_item: payroll_item,
        deduction_type: deduction_type,
        label: "Rent Deduction",
        category: "post_tax",
        amount: 75.00
      )

      expect(described_class.new(pay_period).send(:employee_deductions_total, payroll_item)).to eq(150.00)
    end

    it "dedupes capped mirrored payroll field deductions by payroll-field deduction type" do
      company = create(:company)
      employee = create(:employee, company: company)
      pay_period = create(:pay_period, :committed, company: company)
      deduction_type = DeductionType.create!(company: company, name: "Payroll Field: Rent Deduction (Post Tax)", category: "post_tax", sub_category: "rent")
      payroll_item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company)
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent"
      )
      payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent",
        amount: 50.00,
        source: "manual"
      )
      PayrollItemDeduction.create!(
        payroll_item: payroll_item,
        deduction_type: deduction_type,
        label: "Rent Deduction",
        category: "post_tax",
        amount: 75.00
      )

      expect(described_class.new(pay_period).send(:employee_deductions_total, payroll_item)).to eq(50.00)
    end

    it "does not double-count mirrored payroll field deductions" do
      company = create(:company)
      employee = create(:employee, company: company)
      pay_period = create(:pay_period, :committed, company: company)
      deduction_type = DeductionType.create!(company: company, name: "Payroll Field Rent", category: "post_tax", sub_category: "rent")
      payroll_item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company)
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent"
      )
      payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent",
        amount: 75.00,
        source: "manual"
      )
      PayrollItemDeduction.create!(
        payroll_item: payroll_item,
        deduction_type: deduction_type,
        label: "Rent Deduction",
        category: "post_tax",
        amount: 75.00
      )

      expect(described_class.new(pay_period).send(:employee_deductions_total, payroll_item)).to eq(75.00)
    end
  end
end
