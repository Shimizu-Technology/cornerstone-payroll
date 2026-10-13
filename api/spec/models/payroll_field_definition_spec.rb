# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFieldDefinition, type: :model do
  it "keeps client and employee ownership immutable after creation" do
    field = create(:payroll_field_definition)
    field.owner_employee = create(:employee, company: field.company)
    expect(field).not_to be_valid
    expect(field.errors.full_messages.join).to include("scope cannot be changed")
    field.reload.company = create(:company)
    expect(field).not_to be_valid
  end

  it "rejects changing a linked repayment into a non-loan field without changing saved history" do
    field = create(:payroll_field_definition, kind: "deduction", tax_treatment: "post_tax_deduction", category: "loan")
    worker = create(:employee, company: field.company)
    loan = EmployeeLoan.create!(company: field.company, employee: worker, name: "Linked", original_amount: 500, current_balance: 500)
    worker.employee_payroll_fields.create!(payroll_field_definition: field, employee_loan: loan, amount: 50)
    field.assign_attributes(kind: "addition", tax_treatment: "taxable_addition")
    expect(field).not_to be_valid
    expect(field.errors.full_messages.join).to include("fixed post-tax loan deduction")
    expect(field.reload).to be_deduction
    expect(loan.reload.current_balance).to eq(500)
  end
end
