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
end
