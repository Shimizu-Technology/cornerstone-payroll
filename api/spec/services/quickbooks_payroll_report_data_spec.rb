# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksPayrollReportData do
  it "uses explicit payroll field reporting groups for 401(k) retirement sections" do
    company = create(:company)
    employee = create(:employee, company: company)
    pay_period = create(:pay_period, :committed, company: company)
    payroll_item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company)
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Owner 401(k)",
      kind: "deduction",
      tax_treatment: "pre_tax_deduction",
      category: "retirement",
      reporting_group: PayrollReportingGroups::GROUP_401K_PRE_TAX,
      amount_type: "fixed"
    )
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Owner 401(k)",
      kind: "deduction",
      tax_treatment: "pre_tax_deduction",
      category: "retirement",
      reporting_group: field.reporting_group,
      amount: 100.00,
      source: "manual"
    )

    row = described_class.new(pay_period).retirement_rows.find { |candidate| candidate.employee_name == described_class.new(pay_period).qb_employee_name(employee) }

    expect(row.group).to eq(PayrollReportingGroups::GROUP_401K_PRE_TAX)
    expect(row.employee_amount).to eq(100.00)
  end

  it "keeps Roth 401(k) deductions in after-tax columns without reducing adjusted gross" do
    company = create(:company)
    employee = create(:employee, company: company)
    pay_period = create(:pay_period, :committed, company: company)
    payroll_item = create(
      :payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      gross_pay: 1_000.00,
      net_pay: 900.00
    )
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Roth 401(k)",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "retirement",
      reporting_group: PayrollReportingGroups::GROUP_401K_AFTER_TAX,
      amount_type: "fixed"
    )
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Roth 401(k)",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "retirement",
      reporting_group: field.reporting_group,
      amount: 100.00,
      source: "manual"
    )

    data = described_class.new(pay_period)
    entry = data.deduction_contribution_entries.find { |candidate| candidate.reporting_group == PayrollReportingGroups::GROUP_401K_AFTER_TAX }

    expect(data.employee_adjusted_gross(payroll_item)).to eq(1_000.00)
    expect(data.pre_tax_retirement_deduction_lines_for(payroll_item)).to be_empty
    expect(data.employee_after_tax_total(payroll_item)).to eq(100.00)
    expect(entry.description).to eq("401(k) After Tax")
    expect(entry.type).to eq("Roth 401(k)")
  end

  it "does not double count employer-contribution payroll field entries mirrored as deductions" do
    company = create(:company)
    employee = create(:employee, company: company)
    pay_period = create(:pay_period, :committed, company: company)
    payroll_item = create(
      :payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      gross_pay: 1_000.00,
      net_pay: 1_000.00
    )
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Roth 401(k) Match",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "retirement",
      reporting_group: PayrollReportingGroups::GROUP_401K_AFTER_TAX,
      amount_type: "fixed"
    )
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Roth 401(k) Match",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "retirement",
      reporting_group: field.reporting_group,
      amount: 50.00,
      source: "manual"
    )
    deduction_type = DeductionType.create!(
      company: company,
      name: "Roth 401(k) Match",
      category: "employer_contribution",
      sub_category: "retirement",
      reporting_group: field.reporting_group
    )
    payroll_item.payroll_item_deductions.create!(
      deduction_type: deduction_type,
      amount: 50.00,
      category: "employer_contribution",
      label: "Roth 401(k) Match",
      reporting_group: field.reporting_group
    )

    data = described_class.new(pay_period)
    entry = data.aggregate_deduction_contribution_rows.find { |candidate| candidate.reporting_group == PayrollReportingGroups::GROUP_401K_AFTER_TAX }
    retirement_row = data.retirement_rows.find { |candidate| candidate.group == PayrollReportingGroups::GROUP_401K_AFTER_TAX }

    expect(entry.company_amount).to eq(50.00)
    expect(data.employer_contribution_total(payroll_item)).to eq(50.00)
    expect(data.total_payroll_cost(payroll_item)).to eq(1_050.00)
    expect(retirement_row.company_amount).to eq(50.00)
  end

  it "does not classify an arbitrary payroll field as 401(k) without retirement context or report group" do
    company = create(:company)
    employee = create(:employee, company: company)
    pay_period = create(:pay_period, :committed, company: company)
    payroll_item = create(:payroll_item, pay_period: pay_period, employee: employee, company: company)
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Uniform Repayment",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "other",
      amount_type: "fixed"
    )
    payroll_item.payroll_item_field_entries.create!(
      payroll_field_definition: field,
      label: "Uniform Repayment",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "other",
      amount: 25.00,
      source: "manual"
    )

    data = described_class.new(pay_period)
    entry = data.deduction_contribution_entries.find { |candidate| candidate.description == "Uniform Repayment" }

    expect(entry.reporting_group).to be_nil
    expect(data.retirement_rows).to be_empty
  end
end
