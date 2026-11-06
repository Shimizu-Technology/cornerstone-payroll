# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeYtdTotal, type: :model do
  include HistoricalYtdBridgeFixtureHelper

  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department, employment_type: "hourly", pay_rate: 20.0) }
  let(:ytd) { EmployeeYtdTotal.create!(employee: employee, year: 2026) }

  describe "#subtract_payroll_item! signed reversals" do
    it "preserves signed wage, tax and deduction balances instead of flooring a reversal" do
      item = create(:payroll_item, employee: employee,
        pay_period: create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 1, 30)),
        pay_rate: 10, overtime_hours: 1, gross_pay: 10, net_pay: 10, withholding_tax: 10,
        social_security_tax: 10, medicare_tax: 10, insurance_payment: 10, loan_payment: 10,
        tips_paid_out: 10, reported_tips: 10, bonus: 10)
      fields = %i[gross_pay net_pay withholding_tax social_security_tax medicare_tax insurance loans tips_paid_out tips bonus]
      ytd.update!(fields.index_with { 1 }.merge(overtime_pay: 1))
      ytd.subtract_payroll_item!(item)
      fields.each { |field| expect(ytd.reload.public_send(field)).to eq(-9), field.to_s }
      expect(ytd.overtime_pay).to eq(-14)
    end

    it "retains signed active retirement contributions and the existing historical balance" do
      apply_historical_ytd_balance(company: company, employee: employee, through_pay_date: Date.new(2026, 1, 1),
        retirement: 3, roth_retirement: 4)
      period = create(:pay_period, :committed, company: company,
        start_date: Date.new(2026, 1, 2), end_date: Date.new(2026, 1, 15), pay_date: Date.new(2026, 1, 30))
      original = create(:payroll_item, employee: employee, pay_period: period, retirement_payment: 10, roth_retirement_payment: 10)
      positive = create(:payroll_item, employee: employee, pay_period: create(:pay_period, :committed, company: company,
        start_date: Date.new(2026, 1, 16), end_date: Date.new(2026, 1, 29), pay_date: Date.new(2026, 2, 13)),
        correction_for_payroll_item_id: original.id, retirement_payment: 10, roth_retirement_payment: 10)
      create(:payroll_item, employee: employee, pay_period: create(:pay_period, :committed, company: company,
        start_date: Date.new(2026, 1, 30), end_date: Date.new(2026, 2, 12), pay_date: Date.new(2026, 2, 27)),
        correction_for_payroll_item_id: original.id, retirement_payment: -19, roth_retirement_payment: -19)
      ytd.update!(retirement: 4, roth_retirement: 5)
      ytd.subtract_payroll_item!(positive)
      expect(ytd.reload.retirement).to eq(-6)
      expect(ytd.roth_retirement).to eq(-5)
    end
  end

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
  end
end
