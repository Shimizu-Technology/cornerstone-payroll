# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeYtdTotal, type: :model do
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department, employment_type: "hourly", pay_rate: 20.0) }
  let(:ytd) { EmployeeYtdTotal.create!(employee: employee, year: 2026) }

  describe "#add_payroll_item! / #subtract_payroll_item! overtime consistency" do
    it "uses payroll_item.overtime_pay symmetrically for add and subtract" do
      item = create(:payroll_item,
        employee: employee,
        pay_period: create(:pay_period, company: company),
        employment_type: "hourly",
        pay_rate: 20.0,
        overtime_hours: 5,
        gross_pay: 100.0,
        net_pay: 80.0,
        withholding_tax: 5.0,
        social_security_tax: 2.0,
        medicare_tax: 1.0)

      expected_ot = item.overtime_pay.to_f
      expect(expected_ot).to eq(150.0)

      ytd.add_payroll_item!(item)
      expect(ytd.reload.overtime_pay).to eq(expected_ot)

      ytd.subtract_payroll_item!(item)
      expect(ytd.reload.overtime_pay).to eq(0.0)
    end

    it "does not accumulate phantom overtime for salaried items" do
      salaried_employee = create(:employee, company: company, department: department, employment_type: "salary", pay_rate: 65_000)
      salaried_item = create(:payroll_item,
        employee: salaried_employee,
        pay_period: create(:pay_period, company: company),
        employment_type: "salary",
        pay_rate: 65_000,
        overtime_hours: 10,
        gross_pay: 2_500.0,
        net_pay: 2_000.0,
        withholding_tax: 250.0,
        social_security_tax: 155.0,
        medicare_tax: 36.25)

      expect(salaried_item.overtime_pay.to_f).to eq(0.0)

      ytd.add_payroll_item!(salaried_item)
      expect(ytd.reload.overtime_pay).to eq(0.0)

      ytd.subtract_payroll_item!(salaried_item)
      expect(ytd.reload.overtime_pay).to eq(0.0)
    end
  end
end
