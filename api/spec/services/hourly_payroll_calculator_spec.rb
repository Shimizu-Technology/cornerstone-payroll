# frozen_string_literal: true

require "rails_helper"

RSpec.describe HourlyPayrollCalculator do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:pay_period) { create(:pay_period, company: company, pay_date: Date.new(2024, 1, 19)) }

  # Validation test case from AGENT_INSTRUCTIONS.md
  # Employee: 56.48 hours @ $9.25, single filing
  # Expected: Gross $522.44, SS $32.39, Medicare $7.58, Withholding $0.00, Net $482.47
  describe "validation case: 56.48 hours @ $9.25 single" do
    let(:employee) do
      create(:employee,
        company: company,
        department: department,
        first_name: "Fredly",
        last_name: "Fred",
        employment_type: "hourly",
        pay_rate: 9.25,
        filing_status: "single",
        allowances: 0,
        retirement_rate: 0,
        roth_retirement_rate: 0
      )
    end

    let(:payroll_item) do
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 9.25,
        hours_worked: 56.48,
        overtime_hours: 0,
        reported_tips: 0,
        bonus: 0
      )
    end

    it "calculates correct gross pay" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.gross_pay).to eq(522.44)
    end

    it "calculates correct Social Security" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.social_security_tax).to eq(32.39)
    end

    it "calculates correct Medicare" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.medicare_tax).to eq(7.58)
    end

    it "calculates zero withholding (below threshold)" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.withholding_tax).to eq(0.00)
    end

    it "calculates correct net pay" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      # Net = Gross - Total Deductions
      # Net = 522.44 - (0 + 32.39 + 7.58 + 0 + 0 + 0 + 0) = 482.47
      expect(payroll_item.net_pay).to eq(482.47)
    end
  end

  describe "with overtime" do
    let(:employee) do
      create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 15.00,
        filing_status: "single"
      )
    end

    let(:payroll_item) do
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 15.00,
        hours_worked: 40,
        overtime_hours: 10
      )
    end

    it "calculates overtime at 1.5x rate" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      # Regular: 40 * 15 = 600
      # Overtime: 10 * 15 * 1.5 = 225
      # Total: 825
      expect(payroll_item.gross_pay).to eq(825.00)
    end
  end

  describe "with tips and bonus" do
    let(:employee) do
      create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 10.00,
        filing_status: "single"
      )
    end

    let(:payroll_item) do
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 10.00,
        hours_worked: 40,
        reported_tips: 200.00,
        bonus: 100.00
      )
    end

    it "includes tips and bonus in gross pay" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      # Regular: 40 * 10 = 400
      # Tips: 200
      # Bonus: 100
      # Total: 700
      expect(payroll_item.gross_pay).to eq(700.00)
    end
  end

  describe "with retirement deductions" do
    let(:employee) do
      create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00,
        filing_status: "single",
        retirement_rate: 0.04,    # 4%
        roth_retirement_rate: 0.03 # 3%
      )
    end

    let(:payroll_item) do
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 80
      )
    end

    it "calculates retirement deductions correctly" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      # Gross: 80 * 20 = 1600
      # Retirement: 1600 * 0.04 = 64.00
      # Roth: 1600 * 0.03 = 48.00
      expect(payroll_item.gross_pay).to eq(1600.00)
      expect(payroll_item.retirement_payment).to eq(64.00)
      expect(payroll_item.roth_retirement_payment).to eq(48.00)
    end
  end
end
