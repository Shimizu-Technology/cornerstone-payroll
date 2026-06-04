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
