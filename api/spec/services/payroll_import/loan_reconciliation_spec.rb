# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollImport::LoanReconciliation do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:pay_date) { Date.new(2026, 9, 15) }

  def deduction_type(name)
    DeductionType.create!(company: company, name: name, category: "post_tax", sub_category: "loan", active: true)
  end

  def recurring_loan(amount: 50)
    type = deduction_type("Recurring employee loan")
    loan = EmployeeLoan.create!(
      company: company,
      employee: employee,
      deduction_type: type,
      name: "Recurring employee loan",
      tracking_mode: "recurring_no_balance",
      payment_amount: amount,
      first_deduction_date: pay_date
    )
    employee.employee_deductions.create!(deduction_type: type, amount: amount, is_percentage: false, active: true)
    loan
  end

  def installment_loan(balance: 25, payment: 50)
    type = deduction_type("Installment employee loan")
    loan = EmployeeLoan.create!(
      company: company,
      employee: employee,
      deduction_type: type,
      name: "Installment employee loan",
      original_amount: 200,
      opening_balance: 200,
      current_balance: balance,
      balance_as_of: Date.new(2026, 9, 1),
      balance_source: "statement",
      payment_amount: payment,
      first_deduction_date: pay_date
    )
    employee.employee_deductions.create!(deduction_type: type, amount: payment, is_percentage: false, active: true)
    loan
  end

  it "matches a recurring source amount to its named no-balance ledger" do
    loan = recurring_loan

    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: { loan_deduction: 50, recurring_loan_deduction: 50 }
    ).call

    expect(result).to include(direct_loan_deduction: 0.to_d, errors: [], warnings: [])
    expect(result[:matches]).to contain_exactly(include(employee_loan_id: loan.id, tracking_mode: "recurring_no_balance", amount: 50.to_d))
  end

  it "blocks a workbook amount when no named recurring ledger exists" do
    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: { loan_deduction: 50, recurring_loan_deduction: 50 }
    ).call

    expect(result[:direct_loan_deduction]).to eq(50)
    expect(result[:errors]).to include(/Set up the named recurring deduction/)
  end

  it "keeps a generated one-payroll deduction direct without pretending it is recurring" do
    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: { loan_deduction: 35, one_payroll_deduction: 35 }
    ).call

    expect(result).to include(direct_loan_deduction: 35.to_d, errors: [], warnings: [], matches: [])
  end

  it "recognizes an installment final-payment cap and keeps calculation on the named ledger" do
    loan = installment_loan(balance: 25, payment: 50)

    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: {
        loan_deduction: 50,
        installment_beginning_balance: 25,
        installment_payment: 50,
        installment_estimated_ending_balance: 0
      }
    ).call

    expect(result[:errors]).to be_empty
    expect(result[:warnings]).to include(/will be capped to the remaining \$25.00 balance/)
    expect(result[:direct_loan_deduction]).to eq(0)
    expect(result[:matches]).to contain_exactly(include(employee_loan_id: loan.id, amount: 25.to_d))
  end

  it "accepts an advance only after the verified ledger balance already includes it" do
    installment_loan(balance: 125, payment: 50)

    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: {
        loan_deduction: 50,
        installment_beginning_balance: 100,
        installment_new_amount: 25,
        installment_payment: 50,
        installment_estimated_ending_balance: 75
      }
    ).call

    expect(result[:errors]).to be_empty
    expect(result[:warnings]).to include(/verified balance already includes it/)
  end

  it "blocks a balance mismatch before payroll can be calculated" do
    installment_loan(balance: 80, payment: 50)

    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: {
        loan_deduction: 50,
        installment_beginning_balance: 100,
        installment_payment: 50,
        installment_estimated_ending_balance: 50
      }
    ).call

    expect(result[:errors]).to include(/has \$80.00 in Cornerstone, but the workbook implies \$100.00/)
    expect(result[:direct_loan_deduction]).to eq(50)
  end
end
