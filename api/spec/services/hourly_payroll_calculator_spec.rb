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

    it "records non-taxable pay in the earnings breakdown" do
      payroll_item.non_taxable_pay = 50.00

      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      non_taxable = payroll_item.payroll_item_earnings.find { |earning| earning.category == "non_taxable" }
      expect(non_taxable).to be_present
      expect(non_taxable.label).to eq("Non-Taxable Pay")
      expect(non_taxable.amount).to eq(50.00)
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

    it "applies pre-tax retirement to withholding wages" do
      no_retirement_employee = create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00,
        filing_status: "single",
        retirement_rate: 0.0
      )
      no_retirement_item = create(:payroll_item,
        pay_period: pay_period,
        employee: no_retirement_employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 80
      )
      no_retirement_calculator = described_class.new(no_retirement_employee, no_retirement_item)
      no_retirement_calculator.calculate

      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.withholding_tax).to be < no_retirement_item.withholding_tax
    end

    it "does not double-count retirement sub-category employee deductions when percentage retirement is configured" do
      deduction_type = DeductionType.create!(
        company: company,
        name: "401(k) Pre-Tax",
        category: "pre_tax",
        sub_category: "retirement",
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: deduction_type,
        amount: 64.00,
        is_percentage: false,
        active: true
      )

      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.retirement_payment).to eq(64.00)
      expect(payroll_item.payroll_item_deductions.map(&:label)).not_to include("401(k) Pre-Tax")
      expect(payroll_item.total_deductions).to eq(
        payroll_item.withholding_tax.to_f +
        payroll_item.social_security_tax.to_f +
        payroll_item.medicare_tax.to_f +
        payroll_item.retirement_payment.to_f +
        payroll_item.roth_retirement_payment.to_f
      )
    end

    it "keeps a fixed traditional 401(k) deduction when only roth_retirement_rate is configured" do
      roth_only_employee = create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00,
        filing_status: "single",
        retirement_rate: 0.0,
        roth_retirement_rate: 0.05
      )
      roth_only_item = create(:payroll_item,
        pay_period: pay_period,
        employee: roth_only_employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 80
      )
      traditional_type = DeductionType.create!(
        company: company,
        name: "401(k) Fixed",
        category: "pre_tax",
        sub_category: "retirement",
        active: true
      )
      EmployeeDeduction.create!(
        employee: roth_only_employee,
        deduction_type: traditional_type,
        amount: 40.00,
        is_percentage: false,
        active: true
      )

      described_class.new(roth_only_employee, roth_only_item).calculate

      expect(roth_only_item.roth_retirement_payment).to eq(80.00)
      expect(roth_only_item.payroll_item_deductions.map(&:label)).to include("401(k) Fixed")
    end

    it "keeps a fixed roth deduction when only retirement_rate is configured" do
      traditional_only_employee = create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00,
        filing_status: "single",
        retirement_rate: 0.04,
        roth_retirement_rate: 0.0
      )
      traditional_only_item = create(:payroll_item,
        pay_period: pay_period,
        employee: traditional_only_employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 80
      )
      roth_type = DeductionType.create!(
        company: company,
        name: "Roth 401(k) Fixed",
        category: "post_tax",
        sub_category: "retirement",
        active: true
      )
      EmployeeDeduction.create!(
        employee: traditional_only_employee,
        deduction_type: roth_type,
        amount: 30.00,
        is_percentage: false,
        active: true
      )

      described_class.new(traditional_only_employee, traditional_only_item).calculate

      expect(traditional_only_item.retirement_payment).to eq(64.00)
      expect(traditional_only_item.payroll_item_deductions.map(&:label)).to include("Roth 401(k) Fixed")
    end
  end

  describe "with imported loan deductions and itemized post-tax deductions" do
    let(:employee) do
      create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00,
        filing_status: "single"
      )
    end

    let(:payroll_item) do
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40,
        loan_deduction: 25.00,
        import_source: "mosa_revel"
      )
    end

    before do
      deduction_type = DeductionType.create!(
        company: company,
        name: "Medical Insurance",
        category: "post_tax",
        sub_category: "insurance",
        active: true
      )

      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: deduction_type,
        amount: 10.00,
        is_percentage: false,
        active: true
      )
    end

    it "keeps imported loan deductions in total deductions and net pay" do
      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.loan_payment).to eq(25.00)
      expect(payroll_item.insurance_payment).to eq(10.00)
      expect(payroll_item.total_deductions).to eq(
        payroll_item.withholding_tax.to_f +
        payroll_item.social_security_tax.to_f +
        payroll_item.medicare_tax.to_f +
        35.00
      )
      expect(payroll_item.net_pay).to eq(
        (payroll_item.gross_pay.to_f - payroll_item.total_deductions.to_f).round(2)
      )
    end

    it "does not double-count an imported loan when an employee loan deduction already exists" do
      loan_type = DeductionType.create!(
        company: company,
        name: "Employee Loan",
        category: "post_tax",
        sub_category: "loan",
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: loan_type,
        amount: 25.00,
        is_percentage: false,
        active: true
      )

      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.loan_payment).to eq(25.00)
      expect(payroll_item.total_deductions).to eq(
        payroll_item.withholding_tax.to_f +
        payroll_item.social_security_tax.to_f +
        payroll_item.medicare_tax.to_f +
        payroll_item.insurance_payment.to_f +
        25.00
      )
    end
  end

  describe "with pre-tax insurance deductions" do
    let(:employee) do
      create(:employee,
        company: company,
        department: department,
        employment_type: "hourly",
        pay_rate: 20.00,
        filing_status: "single"
      )
    end

    let(:payroll_item) do
      create(:payroll_item,
        pay_period: pay_period,
        employee: employee,
        employment_type: "hourly",
        pay_rate: 20.00,
        hours_worked: 40
      )
    end

    it "does not double-count pre-tax insurance in total deductions" do
      deduction_type = DeductionType.create!(
        company: company,
        name: "Pre-Tax Medical",
        category: "pre_tax",
        sub_category: "insurance",
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: deduction_type,
        amount: 10.00,
        is_percentage: false,
        active: true
      )

      calculator = described_class.new(employee, payroll_item)
      calculator.calculate

      expect(payroll_item.insurance_payment).to eq(10.00)
      expect(payroll_item.total_deductions).to eq(
        payroll_item.withholding_tax.to_f +
        payroll_item.social_security_tax.to_f +
        payroll_item.medicare_tax.to_f +
        10.00
      )
    end
  end
end
