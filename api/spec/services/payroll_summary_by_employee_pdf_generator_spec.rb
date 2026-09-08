# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollSummaryByEmployeePdfGenerator do
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

    it "shows recurring additions and deductions in the report detail exactly once" do
      company = create(:company)
      employee = create(:employee, company: company)
      pay_period = create(:pay_period, :committed, company: company)
      payroll_item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company,
        gross_pay: 1_100,
        payroll_adjustments: [
          { "label" => "Shift premium", "amount" => 100, "treatment" => "taxable_addition" },
          { "label" => "Employee loan", "amount" => 50, "treatment" => "post_tax_deduction" }
        ],
        custom_columns_data: { PayrollItem::PAYROLL_ADJUSTMENTS_SOURCE_KEY => PayrollItem::EMPLOYEE_DEFAULT_ADJUSTMENTS_SOURCE })

      data = described_class.new(pay_period).data

      expect(data.earnings_lines_for(payroll_item).select { |line| line.label == "Shift premium" }.sum(&:amount)).to eq(100.0)
      expect(data.after_tax_deduction_lines_for(payroll_item).select { |line| line.label == "Employee loan" }.sum(&:amount)).to eq(50.0)
    end
  end
end
