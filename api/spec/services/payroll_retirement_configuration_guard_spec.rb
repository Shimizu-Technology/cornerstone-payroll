# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollRetirementConfigurationGuard do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company), retirement_rate: 0.1) }
  let(:pay_period) { create(:pay_period, company: company, pay_date: Date.new(2024, 1, 19)) }
  let(:item) { create(:payroll_item, employee: employee, pay_period: pay_period, pay_rate: 20, hours_worked: 50) }
  let(:guard) { described_class.new(employee: employee, payroll_item: item) }

  def legacy_deduction(name: "401(k) Fixed", category: "pre_tax", amount: 100, active: true, reporting_group: nil)
    type = DeductionType.create!(company: company, name: name, category: category, sub_category: "retirement", active: true, reporting_group: reporting_group)
    EmployeeDeduction.create!(employee: employee, deduction_type: type, amount: amount, active: active, is_percentage: false)
  end

  def field_assignment(name: "401(k) Fixed", treatment: "pre_tax_deduction", amount: 100, **options)
    field = PayrollFieldDefinition.create!(company: company, name: name,
      kind: treatment == "employer_contribution" ? "employer_contribution" : "deduction",
      tax_treatment: treatment, category: "retirement", amount_type: options.delete(:amount_type) || "fixed",
      default_amount: options.delete(:default_amount), reporting_group: options.delete(:reporting_group))
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: amount, **options)
  end

  def explicit_entry(assignment, amount:, source: "manual", active: true)
    field = assignment.payroll_field_definition
    item.payroll_item_field_entries.build(payroll_field_definition: field, label: field.name,
      kind: field.kind, tax_treatment: field.tax_treatment, category: field.category,
      reporting_group: field.reporting_group, source: source, amount: amount, active: active)
  end

  it "rejects a built-in rate and a legacy fixed contribution instead of silently suppressing it" do
    legacy_deduction

    expect { PayrollCalculator.for(employee, item).calculate }
      .to raise_error(ArgumentError, /Pre-Tax 401\(k\) percentage overlaps recurring deduction/)
    expect(item.gross_pay).to eq(0)
  end

  it "rejects a built-in rate and a flexible fixed contribution" do
    field_assignment

    expect { guard.validate! }.to raise_error(ArgumentError, /payroll field "401\(k\) Fixed"/)
  end

  it "rejects a built-in rate and a flexible percentage contribution before gross has been calculated" do
    field_assignment(amount: nil, amount_type: "percentage", percentage: 5)

    expect { guard.validate! }.to raise_error(ArgumentError, /Retirement setup needs review/)
  end

  it "allows fixed pre-tax contributions alongside Roth percentages" do
    employee.update!(retirement_rate: 0, roth_retirement_rate: 0.05)
    legacy_deduction
    field_assignment(name: "Separate 401(k) Contribution")

    expect { guard.validate! }.not_to raise_error
  end

  it "allows fixed Roth contributions alongside pre-tax percentages" do
    legacy_deduction(name: "Roth 401(k) Fixed", category: "post_tax")
    field_assignment(name: "Roth 401(k) Field", treatment: "post_tax_deduction")

    expect { guard.validate! }.not_to raise_error
  end

  it "rejects a built-in Roth rate and a typed Roth contribution" do
    employee.update!(roth_retirement_rate: 0.05)
    field_assignment(name: "Roth 401(k)", treatment: "post_tax_deduction")

    expect { guard.validate! }.to raise_error(ArgumentError, /Roth 401\(k\) percentage overlaps/)
  end

  it "ignores inactive, expired, future, and explicitly zero recurring fields" do
    field_assignment(name: "Inactive 401(k)", active: false)
    field_assignment(name: "Future 401(k)", start_date: pay_period.pay_date + 1)
    field_assignment(name: "Expired 401(k)", end_date: pay_period.pay_date - 1)
    field_assignment(name: "Zero 401(k)", amount: 0, default_amount: 100)
    legacy_deduction(active: false)

    expect { guard.validate! }.not_to raise_error
  end

  it "does not invent an amount for an unspecified manual field" do
    field_assignment(amount: nil, amount_type: "manual")

    expect { guard.validate! }.not_to raise_error
  end

  it "honors explicit zero paycheck overrides for manual and imported fields" do
    explicit_entry(field_assignment, amount: 0)
    explicit_entry(field_assignment(name: "Imported 401(k)"), amount: 0, source: "import")

    expect { guard.validate! }.not_to raise_error
  end

  it "checks positive paycheck overrides even after their recurring assignment expires" do
    assignment = field_assignment(end_date: pay_period.pay_date - 1)
    explicit_entry(assignment, amount: 25)

    expect { guard.validate! }.to raise_error(ArgumentError, /paycheck field/)
  end

  it "allows explicitly separate retirement plans without deduping their labels or amounts" do
    legacy_deduction(reporting_group: "retirement_other")
    field_assignment(reporting_group: "retirement_other")

    expect { guard.validate! }.not_to raise_error
  end

  it "rejects overlapping employer rates and flexible employer contributions, independently of employee rates" do
    employee.update!(employer_retirement_match_rate: 0.04)
    field_assignment(name: "401(k) Company Contribution", treatment: "employer_contribution")

    expect { guard.validate! }.to raise_error(ArgumentError, /Employer Pre-Tax Match percentage overlaps/)
  end

  it "rejects overlapping employer Roth rates and legacy employer contributions" do
    employee.update!(employer_roth_match_rate: 0.04)
    legacy_deduction(name: "Roth 401(k) Company Contribution", category: "employer_contribution")

    expect { guard.validate! }.to raise_error(ArgumentError, /Employer Roth Match percentage overlaps/)
  end

  it "keeps an independent fixed employer contribution when the employee has a pre-tax percentage" do
    legacy_deduction(name: "401(k) Company Contribution", category: "employer_contribution", amount: 30)

    PayrollCalculator.for(employee, item).calculate

    expect(item.retirement_payment).to eq(100)
    contribution = item.payroll_item_deductions.find { |deduction| deduction.label == "401(k) Company Contribution" }
    expect(contribution.amount).to eq(30)
    expect(contribution).to be_employer_contribution
    expect(item.total_deductions).to eq(item.withholding_tax + item.social_security_tax + item.medicare_tax + 100)
  end

  it "preserves snapshot recalculation behavior without reading current conflicting setup" do
    PayrollCalculator.for(employee, item).calculate
    snapshot = item.calculation_context_snapshot.deep_dup
    original_net = item.net_pay
    legacy_deduction
    field_assignment

    expect(described_class).not_to receive(:new)
    PayrollCalculator.for(employee, item, calculation_context: snapshot).calculate

    expect(item.net_pay).to eq(original_net)
  end

  it "does not apply employee retirement validation to contractor calculations" do
    employee.update_columns(employment_type: "contractor", contractor_pay_type: "flat_fee", contractor_type: "individual")
    legacy_deduction

    expect(described_class).not_to receive(:new)
    expect { PayrollCalculator.for(employee, item).calculate }.not_to raise_error
    expect(item.retirement_payment).to eq(0)
  end

  it "rejects Roth reporting on a pre-tax payroll field even when no built-in rates are set" do
    employee.update!(retirement_rate: 0)
    field_assignment(reporting_group: "401k_after_tax")

    expect { guard.validate! }.to raise_error(ArgumentError, /reported as 401\(k\) After Tax but deducts before taxes/)
  end

  it "rejects pre-tax reporting on a post-tax legacy deduction even without built-in rates" do
    employee.update!(retirement_rate: 0)
    legacy_deduction(category: "post_tax", reporting_group: "401k_pre_tax")

    expect { guard.validate! }.to raise_error(ArgumentError, /reported as 401\(k\) Pre-Tax but deducts after taxes/)
  end

  it "allows either reporting group for independent employer contributions" do
    employee.update!(retirement_rate: 0)
    legacy_deduction(name: "Company Traditional", category: "employer_contribution", reporting_group: "401k_pre_tax")
    field_assignment(name: "Company Roth", treatment: "employer_contribution", reporting_group: "401k_after_tax")

    expect { guard.validate! }.not_to raise_error
  end

  it "does not block payroll on mismatched settings that are inactive or overridden to zero" do
    employee.update!(retirement_rate: 0)
    legacy_deduction(category: "post_tax", reporting_group: "401k_pre_tax", active: false)
    assignment = field_assignment(reporting_group: "401k_after_tax")
    explicit_entry(assignment, amount: 0)
    field_assignment(name: "Future mismatched plan", reporting_group: "401k_after_tax", start_date: pay_period.pay_date + 1)

    expect { guard.validate! }.not_to raise_error
  end

  it "uses the same definition fallback as reporting for an older explicit paycheck field" do
    employee.update!(retirement_rate: 0)
    assignment = field_assignment(reporting_group: "401k_after_tax")
    entry = explicit_entry(assignment, amount: 100)
    entry.reporting_group = nil

    expect { guard.validate! }.to raise_error(ArgumentError, /reported as 401\(k\) After Tax but deducts before taxes/)
  end
end
