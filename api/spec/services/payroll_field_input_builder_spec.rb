# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFieldInputBuilder do
  it "returns a field referenced by a saved payroll item after its employee is terminated" do
    company = create(:company)
    employee = create(:employee, company: company, status: "terminated", termination_date: Date.new(2026, 6, 5))
    pay_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 5, 18),
      end_date: Date.new(2026, 5, 31),
      pay_date: Date.new(2026, 6, 4)
    )
    payroll_item = create(:payroll_item, company: company, employee: employee, pay_period: pay_period)
    field = create(
      :payroll_field_definition,
      company: company,
      name: "Employer Benefit",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "benefit",
      amount_type: "fixed",
      show_in_payroll_grid: true
    )
    create(
      :payroll_item_field_entry,
      payroll_item: payroll_item,
      payroll_field_definition: field,
      label: field.name,
      kind: field.kind,
      tax_treatment: field.tax_treatment,
      category: field.category,
      amount: 12.34,
      source: "employee_default",
      employer_paid: true
    )

    result = described_class.new(pay_period: pay_period, company_id: company.id).call

    expect(result.fetch(:fields).pluck(:id)).to contain_exactly(field.id)
    expect(result.fetch(:assignments)).to be_empty
  end
end
