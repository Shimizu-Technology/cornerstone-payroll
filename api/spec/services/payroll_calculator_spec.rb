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

      result = calculator.send(:find_or_create_employer_deduction_type, label, sub_category: "retirement")

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

      result = calculator.send(:find_or_create_employer_deduction_type, legacy.name, sub_category: "retirement")

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
        calculator.send(:find_or_create_employer_deduction_type, conflicting.name, sub_category: "retirement")
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

    it "does not use stored pay_rate as base pay for variable salary employees without an override" do
      variable_employee = create(
        :employee,
        company: company,
        department: department,
        employment_type: "salary",
        salary_type: "variable",
        pay_rate: 225_062.76,
        pay_frequency: "biweekly"
      )
      variable_item = create(
        :payroll_item,
        employee: variable_employee,
        pay_period: pay_period,
        employment_type: "salary",
        pay_rate: variable_employee.pay_rate,
        salary_override: nil,
        reported_tips: 331.93
      )

      described_class.for(variable_employee, variable_item).calculate

      expect(variable_item.gross_pay).to eq(331.93)
    end

    it "keeps legacy direct insurance deductions when an imported loan deduction is present" do
      payroll_item.import_source = "mosa_revel"
      payroll_item.loan_deduction = 200.0
      payroll_item.loan_payment = 200.0
      payroll_item.insurance_payment = 75.0
      payroll_item.withholding_tax = 10.0
      payroll_item.social_security_tax = 20.0
      payroll_item.medicare_tax = 5.0
      payroll_item.retirement_payment = 0.0
      payroll_item.roth_retirement_payment = 0.0
      payroll_item.payroll_item_deductions.clear

      described_class.new(employee, payroll_item).send(:calculate_totals)

      expect(payroll_item.total_deductions).to eq(310.0)
    end

    it "uses imported loan_deduction as the paycheck loan payment even when itemized loan setup exists" do
      loan_type = DeductionType.create!(
        company: company,
        name: "Loan",
        category: "post_tax",
        sub_category: "loan",
        active: true
      )
      EmployeeDeduction.create!(
        employee: employee,
        deduction_type: loan_type,
        amount: 40.0,
        is_percentage: false,
        active: true
      )
      payroll_item.import_source = "mosa_revel"
      payroll_item.loan_deduction = 200.0

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.loan_payment).to eq(200.0)
      expect(payroll_item.total_deductions.to_f).to be >= 200.0
    end

    it "applies recurring payroll adjustments according to their tax treatment" do
      payroll_item.payroll_adjustments = [
        { "label" => "Taxable Bonus", "amount" => 100.0, "treatment" => "taxable_addition", "active" => true },
        { "label" => "Mileage", "amount" => 25.0, "treatment" => "non_taxable_addition", "active" => true },
        { "label" => "Approved Pre-Tax", "amount" => 40.0, "treatment" => "pre_tax_deduction", "active" => true },
        { "label" => "Rent Repayment", "amount" => 30.0, "treatment" => "post_tax_deduction", "active" => true }
      ]

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.gross_pay).to eq(1_100.0)
      expect(payroll_item.total_additions).to eq(125.0)
      expect(payroll_item.total_deductions).to be >= 70.0
      expect(payroll_item.payroll_item_earnings.map(&:label)).to include("Taxable Bonus", "Mileage")
    end

    it "snapshots assigned payroll fields into the payroll item and applies their tax treatment" do
      taxable_field = PayrollFieldDefinition.create!(
        company: company,
        name: "Client Bonus",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount_type: "fixed",
        default_amount: 100.0
      )
      deduction_field = PayrollFieldDefinition.create!(
        company: company,
        name: "Auto Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount_type: "fixed",
        default_amount: 75.0
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: taxable_field, amount: 125.0)
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: deduction_field, amount: 80.0)

      described_class.for(employee, payroll_item).calculate

      entries = payroll_item.payroll_item_field_entries.map { |entry| [ entry.label, entry.amount.to_f ] }.to_h
      expect(entries).to include("Client Bonus" => 125.0, "Auto Loan" => 80.0)
      expect(payroll_item.gross_pay).to eq(1_125.0)
      expect(payroll_item.total_deductions.to_f).to be >= 80.0
      expect(payroll_item.payroll_item_earnings.map(&:label)).to include("Client Bonus")
    end

    it "does not compound percentage-based taxable additions across recalculations" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Commission Bonus",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount_type: "percentage",
        default_percentage: 10.0
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, percentage: 10.0)

      3.times { described_class.for(employee, payroll_item).calculate }

      entry = payroll_item.payroll_item_field_entries.find { |candidate| candidate.label == "Commission Bonus" }
      expect(entry.amount.to_f).to eq(100.0)
      expect(payroll_item.gross_pay.to_f).to eq(1_100.0)
    end

    it "calculates percentage deductions against gross after taxable field additions" do
      bonus_field = PayrollFieldDefinition.create!(
        company: company,
        name: "Commission Bonus",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount_type: "percentage",
        default_percentage: 10.0
      )
      deduction_field = PayrollFieldDefinition.create!(
        company: company,
        name: "401(k)",
        kind: "deduction",
        tax_treatment: "pre_tax_deduction",
        category: "retirement",
        amount_type: "percentage",
        default_percentage: 10.0
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: bonus_field, percentage: 10.0)
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: deduction_field, percentage: 10.0)

      described_class.for(employee, payroll_item).calculate

      entries = payroll_item.payroll_item_field_entries.index_by(&:label)
      expect(entries["Commission Bonus"].amount.to_f).to eq(100.0)
      expect(entries["401(k)"].amount.to_f).to eq(110.0)
      expect(payroll_item.gross_pay.to_f).to eq(1_100.0)
    end

    it "recomputes default percentage payroll fields when pay changes before manual override" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "401(k)",
        kind: "deduction",
        tax_treatment: "pre_tax_deduction",
        category: "retirement",
        amount_type: "percentage",
        default_percentage: 5.0
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, percentage: 5.0)

      described_class.for(employee, payroll_item).calculate
      expect(payroll_item.payroll_item_field_entries.find { |entry| entry.label == "401(k)" }.amount.to_f).to eq(50.0)

      payroll_item.hours_worked = 80
      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.payroll_item_field_entries.find { |entry| entry.label == "401(k)" }.amount.to_f).to eq(40.0)
    end

    it "deactivates stale overridden field entries when an assignment is removed" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Stale Bonus",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount_type: "fixed",
        default_amount: 100.0
      )
      assignment = EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 100.0)

      described_class.for(employee, payroll_item).calculate
      entry = payroll_item.payroll_item_field_entries.find { |candidate| candidate.label == "Stale Bonus" }
      entry.update!(source: "manual", amount: 150.0)
      payroll_item.mark_payroll_field_entries_overridden!
      assignment.update!(active: false)

      described_class.for(employee, payroll_item).calculate

      expect(entry).not_to be_active
      expect(payroll_item.gross_pay.to_f).to eq(1_000.0)
    end

    it "restores manually overridden payroll field deductions after an insufficient-pay cap" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Manual Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount_type: "manual"
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 2_000.0)
      payroll_item.payroll_item_field_entries.build(
        payroll_field_definition: field,
        label: "Manual Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount: 2_000.0,
        source: "manual",
        employee_paid: true,
        active: true
      )
      payroll_item.mark_payroll_field_entries_overridden!

      described_class.for(employee, payroll_item).calculate
      capped_amount = payroll_item.payroll_item_field_entries.find { |entry| entry.label == "Manual Loan" }.amount.to_f
      expect(capped_amount).to be < 2_000.0

      payroll_item.hours_worked = 300
      described_class.for(employee, payroll_item).calculate

      restored = payroll_item.payroll_item_field_entries.find { |entry| entry.label == "Manual Loan" }
      expect(restored.amount.to_f).to eq(2_000.0)
      expect(restored.metadata).not_to have_key("uncapped_amount")
    end

    it "does not double-deduct a MoSa imported loan with assigned loan payroll fields" do
      loan_field = PayrollFieldDefinition.create!(
        company: company,
        name: "MoSa Auto Loan",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "loan",
        amount_type: "fixed",
        default_amount: 75.0
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: loan_field, amount: 75.0)
      payroll_item.import_source = "mosa_revel"
      payroll_item.loan_deduction = 200.0

      described_class.for(employee, payroll_item).calculate

      expect(payroll_item.payroll_item_field_entries.map(&:label)).not_to include("MoSa Auto Loan")
      expect(payroll_item.loan_payment).to eq(200.0)
    end

    it "records employer contribution payroll fields separately from employee deductions" do
      contribution_field = PayrollFieldDefinition.create!(
        company: company,
        name: "Employer Health",
        kind: "employer_contribution",
        tax_treatment: "employer_contribution",
        category: "insurance",
        amount_type: "fixed",
        default_amount: 50.0
      )
      EmployeePayrollField.create!(employee: employee, payroll_field_definition: contribution_field, amount: 60.0)

      described_class.for(employee, payroll_item).calculate

      contribution = payroll_item.payroll_item_field_entries.find { |entry| entry.label == "Employer Health" }
      expect(contribution).to be_employer_contribution
      deduction = payroll_item.payroll_item_deductions.find { |item_deduction| item_deduction.label == "Employer Health" }
      expect(deduction.deduction_type.sub_category).to eq("insurance")
      expect(payroll_item.payroll_item_deductions.select(&:employer_contribution?).map(&:label)).to include("Employer Health")
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

    it "does not use employer contribution records to absorb employee deduction excess" do
      employee.update!(
        additional_withholding: 0,
        employer_retirement_match_rate: 0.5
      )
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
        amount: 75.0,
        is_percentage: false,
        active: true
      )
      payroll_item.update!(
        hours_worked: 10,
        overtime_hours: 0,
        holiday_hours: 0,
        pto_hours: 0,
        bonus: 0,
        reported_tips: 0,
        withholding_tax_override: 150.0,
        custom_deductions: []
      )

      payroll_item.calculate!

      employer_match = payroll_item.payroll_item_deductions.find(&:employer_contribution?)
      expect(employer_match.amount).to eq(50.0)
      expect(payroll_item.loan_payment).to eq(0.0)
      expect(payroll_item.withholding_tax).to eq(92.35)
      expect(payroll_item.total_deductions).to eq(payroll_item.gross_pay)
      expect(payroll_item.net_pay).to eq(0.0)
    end

    it "preserves import-sourced loan mirrors when there are no itemized deductions" do
      employee.update!(additional_withholding: 0)
      payroll_item.update!(
        hours_worked: 10,
        overtime_hours: 0,
        holiday_hours: 0,
        pto_hours: 0,
        bonus: 0,
        reported_tips: 0,
        withholding_tax_override: 100.0,
        loan_deduction: 30.0,
        loan_payment: 30.0,
        import_source: "mosa_revel",
        custom_deductions: []
      )

      payroll_item.calculate!

      expect(payroll_item.reload.payroll_item_deductions).to be_empty
      expect(payroll_item.loan_payment).to eq(30.0)
      expect(payroll_item.withholding_tax).to eq(62.35)
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
