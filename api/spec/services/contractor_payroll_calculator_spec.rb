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

  it "pays hours reported as overtime at the contract rate, as one contract labor row" do
    payroll_item.update!(hours_worked: 10, overtime_hours: 2, loan_payment: 0, insurance_payment: 0)

    described_class.new(employee, payroll_item).calculate

    expect(payroll_item.gross_pay).to eq(300.0)
    expect(payroll_item.payroll_item_earnings.map { |earning| earning.slice(:category, :label, :hours, :rate, :amount).symbolize_keys }).to eq([
      { category: "regular", label: "Contract Labor", hours: 12, rate: 25, amount: 300 }
    ])
    expect(payroll_item).to have_attributes(hours_worked: 10, overtime_hours: 2)
  end

  it "combines each rate's regular and source overtime hours into one row, keeping the item's split" do
    rate = employee.employee_wage_rates.create!(label: "Flight Hours", rate: 30, is_primary: true, active: true)
    payroll_item.update!(loan_payment: 0, insurance_payment: 0)
    payroll_item.wage_rate_hours = [
      { employee_wage_rate_id: rate.id, label: "Flight Hours · AIRE current period · $30.00/hr", rate: 30, regular_hours: 60.6,
        overtime_hours: 1.2, holiday_hours: 0, pto_hours: 0, is_primary: true, active: true },
      { employee_wage_rate_id: rate.id, label: "Admin Duties · AIRE current period · $15.00/hr", rate: 15, regular_hours: 14,
        overtime_hours: 0, holiday_hours: 0, pto_hours: 0, is_primary: false, active: true }
    ]

    payroll_item.calculate!

    expect(payroll_item.reload).to have_attributes(gross_pay: 2064.0, hours_worked: 74.6, overtime_hours: 1.2)
    expect(payroll_item.payroll_item_earnings.map(&:category).uniq).to eq([ "regular" ])
    expect(payroll_item.payroll_item_earnings.map { |earning| [ earning.label, earning.hours, earning.rate, earning.amount ] }).to contain_exactly(
      [ "Flight Hours · AIRE current period · $30.00/hr", 61.8, 30, 1854 ],
      [ "Admin Duties · AIRE current period · $15.00/hr", 14, 15, 210 ]
    )
    expect(payroll_item.payroll_item_earnings.map(&:label).grep(/OT/)).to be_empty
  end

  it "nets a signed REG/OT reclassification to the contract-rate hours actually worked" do
    rate = employee.employee_wage_rates.create!(label: "Flight Hours", rate: 100, is_primary: true, active: true)
    payroll_item.update!(loan_payment: 0, insurance_payment: 0)
    payroll_item.wage_rate_hours = [
      { employee_wage_rate_id: rate.id, label: "Flight Hours · correction", rate: 100, regular_hours: 1, overtime_hours: -1,
        holiday_hours: 0, pto_hours: 0, is_primary: true, active: true },
      { employee_wage_rate_id: rate.id, label: "Admin Duties · current", rate: 10, regular_hours: 0, overtime_hours: 1,
        holiday_hours: 0, pto_hours: 0, is_primary: false, active: true }
    ]

    payroll_item.calculate!

    expect(payroll_item.reload.gross_pay).to eq(10.0)
    expect(payroll_item.payroll_item_earnings.map { |earning| [ earning.category, earning.label, earning.hours, earning.amount ] }).to eq([
      [ "regular", "Admin Duties · current", 1, 10 ]
    ])
  end

  it "persists mandatory service charges without applying employee payroll taxes" do
    payroll_item.service_charge_wages = 30.00

    payroll_item.calculate!

    service_charge = payroll_item.reload.payroll_item_earnings.find_by(category: "service_charge")
    expect(service_charge).to be_present
    expect(service_charge.amount).to eq(30.00)
    expect(payroll_item.gross_pay).to eq(280.00)
    expect(payroll_item.net_pay).to eq(280.00)
    expect(payroll_item.social_security_tax).to eq(0.00)
    expect(payroll_item.medicare_tax).to eq(0.00)
  end

  it "does not repeat an automatic flat fee in a tips-only run" do
    employee.update!(contractor_pay_type: "flat_fee", pay_rate: 3_000)
    pay_period.update!(run_purpose: "off_cycle_tips", includes_base_salary: false)
    payroll_item.update!(pay_rate: 3_000, hours_worked: 0)

    payroll_item.calculate!

    expect(payroll_item.reload).to have_attributes(gross_pay: 0.to_d, net_pay: 0.to_d)
    expect(payroll_item.payroll_item_earnings.where(category: "contract_fee")).to be_empty
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

  it "preserves contractor custom deductions and payroll adjustment deductions" do
    payroll_item.custom_deductions = [ { "label" => "Rent", "amount" => 15.00 } ]
    payroll_item.payroll_adjustments = [
      { "label" => "Supplies", "amount" => 10.00, "treatment" => "post_tax_deduction", "active" => true },
      { "label" => "Pre-tax Plan", "amount" => 5.00, "treatment" => "pre_tax_deduction", "active" => true }
    ]

    described_class.new(employee, payroll_item).calculate

    expect(payroll_item.total_deductions.to_f).to eq(30.0)
    expect(payroll_item.net_pay.to_f).to eq(payroll_item.gross_pay.to_f - 30.0)
  end

  it "reduces contractor net pay for explicitly assigned payroll field deductions" do
    post_tax_field = PayrollFieldDefinition.create!(
      company: company,
      name: "Contractor Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount_type: "fixed",
      default_amount: 25.00
    )
    pre_tax_field = PayrollFieldDefinition.create!(
      company: company,
      name: "Contractor Plan Deduction",
      kind: "deduction",
      tax_treatment: "pre_tax_deduction",
      category: "benefit",
      amount_type: "fixed",
      default_amount: 10.00
    )
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: post_tax_field, amount: 25.00)
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: pre_tax_field, amount: 10.00)

    described_class.new(employee, payroll_item).calculate

    expect(payroll_item.payroll_item_field_entries.find { |entry| entry.label == "Contractor Rent Deduction" }.amount.to_f).to eq(25.0)
    expect(payroll_item.payroll_item_field_entries.find { |entry| entry.label == "Contractor Plan Deduction" }.amount.to_f).to eq(10.0)
    employee_paid_deductions = payroll_item.payroll_item_deductions.reject(&:employer_contribution?)
    expect(employee_paid_deductions.map(&:label)).to contain_exactly("Contractor Rent Deduction", "Contractor Plan Deduction")
    expect(employee_paid_deductions.map { |deduction| deduction.amount.to_f }.sum).to eq(35.0)
    expect(payroll_item.total_deductions.to_f).to eq(35.0)
    expect(payroll_item.net_pay.to_f).to eq(payroll_item.gross_pay.to_f - 35.0)
  end

  it "itemizes payroll field deductions when the field label collides with another deduction type category" do
    DeductionType.create!(
      company: company,
      name: "Health Insurance",
      category: "pre_tax",
      sub_category: "insurance",
      active: true
    )
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Health Insurance",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "insurance",
      amount_type: "fixed",
      default_amount: 25.00
    )
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 25.00)

    expect { described_class.new(employee, payroll_item).calculate }.not_to raise_error

    deduction = payroll_item.payroll_item_deductions.reject(&:employer_contribution?).find { |item_deduction| item_deduction.label == "Health Insurance" }
    expect(deduction).to be_present
    expect(deduction.category).to eq("post_tax")
    expect(deduction.deduction_type.name).to eq("Payroll Field: Health Insurance (Post Tax)")
    expect(payroll_item.total_deductions.to_f).to eq(25.0)
  end

  it "uses a collision-safe payroll field deduction type name when a legacy type already owns the generated name" do
    DeductionType.create!(
      company: company,
      name: "Payroll Field: Health Insurance (Post Tax)",
      category: "pre_tax",
      sub_category: "insurance",
      active: true
    )
    field = PayrollFieldDefinition.create!(
      company: company,
      name: "Health Insurance",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "insurance",
      amount_type: "fixed",
      default_amount: 25.00
    )
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, amount: 25.00)

    expect { described_class.new(employee, payroll_item).calculate }.not_to raise_error

    deduction = payroll_item.payroll_item_deductions.reject(&:employer_contribution?).find { |item_deduction| item_deduction.label == "Health Insurance" }
    expect(deduction).to be_present
    expect(deduction.category).to eq("post_tax")
    expect(deduction.deduction_type.name).to eq("Payroll Field Post Tax: Health Insurance")
    expect(payroll_item.total_deductions.to_f).to eq(25.0)
  end

  it "does not accumulate payroll field deduction rows on recalculation" do
    deduction_field = PayrollFieldDefinition.create!(
      company: company,
      name: "Contractor Rent Deduction",
      kind: "deduction",
      tax_treatment: "post_tax_deduction",
      category: "rent",
      amount_type: "fixed",
      default_amount: 25.00
    )
    contribution_field = PayrollFieldDefinition.create!(
      company: company,
      name: "Contractor Admin Fee",
      kind: "employer_contribution",
      tax_treatment: "employer_contribution",
      category: "other",
      amount_type: "fixed",
      default_amount: 10.00
    )
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: deduction_field, amount: 25.00)
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: contribution_field, amount: 10.00)

    described_class.new(employee, payroll_item).calculate
    payroll_item.save!
    first_labels = payroll_item.reload.payroll_item_deductions.map(&:label)

    described_class.new(employee, payroll_item).calculate
    payroll_item.save!
    second_labels = payroll_item.reload.payroll_item_deductions.map(&:label)

    expect(first_labels).to match_array([ "Contractor Rent Deduction", "Contractor Admin Fee" ])
    expect(second_labels).to match_array(first_labels)
    expect(payroll_item.payroll_item_deductions.count).to eq(2)
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
