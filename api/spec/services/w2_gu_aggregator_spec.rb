require "rails_helper"

RSpec.describe W2GuAggregator do
  let(:company) { create(:company, name: "Guam Biz Inc", ein: "91-1234567") }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department, ssn_encrypted: "123-45-6789") }

  describe "#generate" do
    it "logs a warning when reported tips exceed gross pay" do
      pay_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 1, 1),
        end_date: Date.new(2025, 1, 14),
        pay_date: Date.new(2025, 1, 18))

      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        gross_pay: 50.0,
        reported_tips: 100.0,
        withholding_tax: 0.0,
        social_security_tax: 3.1,
        medicare_tax: 0.73)

      allow(Rails.logger).to receive(:warn)

      described_class.new(company, 2025).generate

      expect(Rails.logger).to have_received(:warn).with(include("reported_tips=100.0 exceed gross_pay=50.0"))
    end

    it "excludes voided payroll items from W-2GU boxes and totals" do
      live_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 2, 1),
        end_date: Date.new(2025, 2, 14),
        pay_date: Date.new(2025, 2, 18))
      voided_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 2, 15),
        end_date: Date.new(2025, 2, 28),
        pay_date: Date.new(2025, 3, 4))

      create(:payroll_item,
        pay_period: live_period,
        employee: employee,
        gross_pay: 1_000.0,
        withholding_tax: 100.0,
        social_security_tax: 62.0,
        medicare_tax: 14.5,
        retirement_payment: 50.0,
        reported_tips: 25.0)
      create(:payroll_item, :voided,
        pay_period: voided_period,
        employee: employee,
        gross_pay: 500.0,
        withholding_tax: 50.0,
        social_security_tax: 31.0,
        medicare_tax: 7.25,
        retirement_payment: 10.0,
        reported_tips: 10.0)

      report = described_class.new(company, 2025).generate
      row = report[:employees].find { |employee_row| employee_row[:employee_id] == employee.id }

      expect(row[:box1_wages_tips_other_comp]).to eq(950.0)
      expect(row[:box2_federal_income_tax_withheld]).to eq(100.0)
      expect(row[:box4_social_security_tax_withheld]).to eq(62.0)
      expect(row[:box6_medicare_tax_withheld]).to eq(14.5)
      expect(row[:reported_tips_total]).to eq(25.0)
      expect(report[:totals][:box1_wages_tips_other_comp]).to eq(950.0)
    end


    it "uses committed 2026 tax bases and emits TP, TT, and Box 14b data" do
      pay_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 1, 1),
        end_date: Date.new(2026, 1, 14),
        pay_date: Date.new(2026, 1, 18))
      create(:employee_tipped_occupation,
        employee: employee,
        occupation_code: "101",
        effective_from: Date.new(2026, 1, 1))
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        gross_pay: 1_200.0,
        reported_tips: 200.0,
        cash_tips_reported: 200.0,
        social_security_taxable_wages: 1_000.0,
        social_security_taxable_tips: 200.0,
        medicare_taxable_wages: 1_200.0,
        qualified_overtime_compensation: 50.0,
        withholding_tax: 100.0,
        social_security_tax: 74.4,
        medicare_tax: 17.4)

      report = described_class.new(company, 2026).generate
      row = report[:employees].sole

      expect(row[:box3_social_security_wages]).to eq(1_000.0)
      expect(row[:box7_social_security_tips]).to eq(200.0)
      expect(row[:box5_medicare_wages_tips]).to eq(1_200.0)
      expect(row[:box12]).to include(
        include(code: "TP", amount: 200.0),
        include(code: "TT", amount: 50.0)
      )
      expect(row[:box14b_tipped_occupation_codes]).to eq([ "101" ])
      expect(report[:totals][:box12_code_tp_total]).to eq(200.0)
      expect(report[:totals][:box12_code_tt_total]).to eq(50.0)
    end
  end
end
