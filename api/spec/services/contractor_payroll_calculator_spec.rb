require "rails_helper"

RSpec.describe ContractorPayrollCalculator do
  let!(:company) { create(:company) }
  let!(:department) { create(:department, company: company) }
  let!(:tax_table) { create(:tax_table) }
  let(:pay_period) { create(:pay_period, company: company, pay_date: Date.new(2024, 1, 19)) }

  let(:employee) do
    create(:employee,
      company: company,
      department: department,
      employment_type: "contractor",
      contractor_type: "individual",
      contractor_pay_type: "hourly",
      pay_rate: 25.00
    )
  end

  let(:payroll_item) do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      employment_type: "contractor",
      pay_rate: 25.00,
      hours_worked: 10,
      loan_payment: 15.00,
      insurance_payment: 5.00
    )
  end

  it "records employer contribution payroll field entries without reducing contractor net pay" do
    contribution_field = PayrollFieldDefinition.create!(
      company: company,
      name: "Contractor Admin Fee",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "other",
      amount_type: "fixed",
      default_amount: 25.00
    )
    EmployeePayrollField.create!(
      employee: employee,
      payroll_field_definition: contribution_field,
      amount: 25.00
    )

    described_class.new(employee, payroll_item).calculate

    contribution = payroll_item.payroll_item_deductions.find { |deduction| deduction.label == "Contractor Admin Fee" }
    expect(contribution).to be_present
    expect(contribution.category).to eq("employer_contribution")
    expect(contribution.amount.to_f).to eq(25.0)
    expect(payroll_item.total_deductions).to eq(0)
    expect(payroll_item.net_pay).to eq(payroll_item.gross_pay)
  end

  it "clears stale deductions from a prior non-contractor calculation" do
    deduction_type = DeductionType.create!(
      company: company,
      name: "Medical Insurance",
      category: "post_tax",
      sub_category: "insurance",
      active: true
    )
    payroll_item.payroll_item_deductions.create!(
      deduction_type: deduction_type,
      amount: 12.00,
      category: "post_tax",
      label: "Medical Insurance"
    )

    described_class.new(employee, payroll_item).calculate

    expect(payroll_item.payroll_item_deductions).to be_empty
    expect(payroll_item.loan_payment).to eq(0)
    expect(payroll_item.insurance_payment).to eq(0)
    expect(payroll_item.total_deductions).to eq(0)
    expect(payroll_item.net_pay).to eq(payroll_item.gross_pay)
  end
end
