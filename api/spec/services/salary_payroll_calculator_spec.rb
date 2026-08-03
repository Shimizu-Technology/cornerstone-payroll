# frozen_string_literal: true

require "rails_helper"

RSpec.describe SalaryPayrollCalculator do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:pay_period) { create(:pay_period, company: company, pay_date: Date.new(2024, 1, 19)) }
  let(:employee) do
    create(
      :employee,
      :salary,
      company: company,
      department: department,
      salary_type: "annual",
      pay_frequency: "biweekly"
    )
  end
  let(:payroll_item) do
    create(
      :payroll_item,
      :salary,
      pay_period: pay_period,
      employee: employee,
      service_charge_wages: 25.00
    )
  end

  it "persists mandatory service charges as taxable earnings" do
    payroll_item.calculate!

    service_charge = payroll_item.reload.payroll_item_earnings.find_by(category: "service_charge")
    expect(service_charge).to be_present
    expect(service_charge.label).to eq("Service Charges")
    expect(service_charge.amount).to eq(25.00)
    expect(payroll_item.gross_pay).to eq(2025.00)
    expect(payroll_item.fit_taxable_wages).to eq(2025.00)
    expect(payroll_item.medicare_taxable_wages).to eq(2025.00)
  end

  it "calculates a high annual salary without overflowing the stored pay rate" do
    employee.update!(pay_rate: 5_460_000)
    payroll_item.update!(pay_rate: employee.pay_rate, service_charge_wages: 0)

    payroll_item.calculate!

    expect(payroll_item.reload.gross_pay).to eq(210_000.00)
    expect(payroll_item.medicare_tax).to be_positive
    expect(payroll_item.additional_medicare_tax).to be_positive
  end

  it "never adds base salary to an off-cycle tips run" do
    pay_period.update!(run_purpose: "off_cycle_tips", includes_base_salary: false)
    payroll_item.update!(reported_tips: 125.00, service_charge_wages: 0, salary_override: 500.00)

    payroll_item.calculate!

    expect(payroll_item.reload.gross_pay).to eq(125.00)
    expect(payroll_item.payroll_item_earnings.where(category: "salary")).to be_empty
    expect(payroll_item.payroll_item_earnings.find_by(category: "tips").amount).to eq(125.00)
  end
end
