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

  it "deducts a one-time or varying loan directly when no recurring ledger is set up" do
    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: { loan_deduction: 50, recurring_loan_deduction: 50 }
    ).call

    expect(result).to include(direct_loan_deduction: 50.to_d, errors: [], warnings: [], matches: [])
  end

  it "still reconciles to a set-up recurring ledger so its deduction is not taken twice" do
    recurring_loan(amount: 50)

    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: { loan_deduction: 40, recurring_loan_deduction: 40 }
    ).call

    expect(result[:errors]).to include(/is \$50.00 for this payday, but the workbook says \$40.00/)
    expect(result[:matches]).to be_empty
  end

  it "flags a workbook amount for a paused recurring ledger instead of deducting it directly" do
    recurring_loan(amount: 50).suspend!

    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: { loan_deduction: 50, recurring_loan_deduction: 50 }
    ).call

    expect(result[:errors]).to include(/Recurring employee loan is paused or not scheduled for this payday/)
    expect(result[:matches]).to be_empty
  end

  it "keeps blocking installment amounts until the balance-tracked loan is set up, and offers the setup from the workbook" do
    result = described_class.new(
      employee: employee,
      pay_date: pay_date,
      source_row: { loan_deduction: 50, installment_beginning_balance: 200, installment_new_amount: 100,
        installment_payment: 50, installment_estimated_ending_balance: 250, installment_row_count: 1 }
    ).call

    expect(result[:errors]).to contain_exactly(/installment loan for #{employee.full_name} \(\$300.00 balance, \$50.00 this payroll\), but Employee Loans has none/)
    expect(result[:installment_setup]).to eq(action: "create", name: "Installment loan", starting_balance: "300.0", payment_amount: "50.0",
      first_deduction_date: "2026-09-15", beginning_balance: "200.0", new_amount: "100.0", estimated_ending_balance: "250.0",
      message: result[:errors].sole)
  end

  it "offers a brand-new loan given only as a new amount, and it reconciles once set up" do
    row = { loan_deduction: 25, installment_new_amount: 300, installment_payment: 25, installment_estimated_ending_balance: 275, installment_row_count: 1 }
    offer = described_class.new(employee: employee, pay_date: pay_date, source_row: row).call
    expect(offer[:installment_setup]).to include(action: "create", starting_balance: "300.0", beginning_balance: "0.0")

    loan = installment_loan(balance: 300, payment: 25)
    result = described_class.new(employee: employee, pay_date: pay_date, source_row: row).call
    expect(result[:errors]).to be_empty
    expect(result[:installment_setup]).to be_nil
    expect(result[:matches]).to contain_exactly(include(employee_loan_id: loan.id, amount: 25.to_d))
  end

  it "offers to resume a paused installment loan instead of a second loan" do
    loan = installment_loan(balance: 200, payment: 50)
    loan.suspend!

    result = described_class.new(employee: employee, pay_date: pay_date,
      source_row: { loan_deduction: 50, installment_beginning_balance: 200, installment_payment: 50, installment_row_count: 1 }).call

    expect(result[:errors]).to contain_exactly("Installment employee loan for #{employee.full_name} is paused in Employee Loans. Resume it so this payroll deducts the installment.")
    expect(result[:installment_setup]).to include(action: "resume", employee_loan_id: loan.id, name: "Installment employee loan", current_balance: "200.0")
  end

  it "never offers a second loan when Cornerstone already paid off the installment the workbook still shows" do
    loan = installment_loan(balance: 20, payment: 50)
    loan.record_payment!(amount: 20, date: pay_date - 14)
    expect(loan.reload).to be_paid_off

    result = described_class.new(employee: employee, pay_date: pay_date,
      source_row: { loan_deduction: 20, installment_beginning_balance: 20, installment_payment: 20, installment_row_count: 1 }).call

    expect(result[:installment_setup]).to be_nil
    expect(result[:errors]).to contain_exactly(
      "#{employee.full_name}'s installment loan Installment employee loan was paid off on #{loan.paid_off_date.strftime('%-m/%-d/%Y')} in Employee Loans, but the workbook still shows $20.00. Check the workbook with the client."
    )

    # A brand-new advance after the payoff is a new loan.
    fresh = described_class.new(employee: employee, pay_date: pay_date,
      source_row: { loan_deduction: 25, installment_new_amount: 300, installment_payment: 25, installment_row_count: 1 }).call
    expect(fresh[:installment_setup]).to include(action: "create", starting_balance: "300.0")
  end

  it "does not offer a setup when the workbook has several installment rows for one person" do
    result = described_class.new(employee: employee, pay_date: pay_date,
      source_row: { loan_deduction: 80, installment_beginning_balance: 200, installment_payment: 80, installment_row_count: 2 }).call

    expect(result[:errors]).to contain_exactly(/The workbook has 2 installment loan rows for #{employee.full_name}/)
    expect(result[:installment_setup]).to be_nil
  end

  it "does not offer a second loan when the existing one is not scheduled for this payday" do
    loan = installment_loan(balance: 200, payment: 50)
    loan.update!(first_deduction_date: pay_date + 14)
    employee.employee_deductions.update_all(active: false)

    result = described_class.new(employee: employee, pay_date: pay_date,
      source_row: { loan_deduction: 50, installment_beginning_balance: 200, installment_payment: 50, installment_row_count: 1 }).call

    expect(result[:errors]).to contain_exactly(/Installment employee loan for #{employee.full_name} isn't scheduled for this payday/)
    expect(result[:installment_setup]).to be_nil
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
