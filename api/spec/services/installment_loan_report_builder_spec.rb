# frozen_string_literal: true

require "rails_helper"

RSpec.describe InstallmentLoanReportBuilder do
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department, first_name: "Mina", last_name: "Terlaje") }
  let(:loan) do
    EmployeeLoan.create!(
      employee: employee,
      company: company,
      name: "Tool Advance",
      original_amount: 200.00,
      current_balance: 75.00,
      payment_amount: 25.00,
      start_date: Date.new(2026, 1, 1),
      status: "active"
    )
  end

  before do
    loan.loan_transactions.create!(
      transaction_type: "addition",
      amount: 200.00,
      balance_before: 0.00,
      balance_after: 200.00,
      transaction_date: Date.new(2026, 1, 1)
    )
    loan.loan_transactions.create!(
      transaction_type: "payment",
      amount: 50.00,
      balance_before: 200.00,
      balance_after: 150.00,
      transaction_date: Date.new(2026, 2, 1)
    )
    loan.loan_transactions.create!(
      transaction_type: "payment",
      amount: 75.00,
      balance_before: 150.00,
      balance_after: 75.00,
      transaction_date: Date.new(2026, 4, 1)
    )
  end

  it "filters transactions and derives the balance as of the requested date" do
    snapshot = described_class.new(company, as_of_date: Date.new(2026, 3, 1)).loans.first

    expect(snapshot[:transactions].map(&:transaction_date)).to eq([
      Date.new(2026, 1, 1),
      Date.new(2026, 2, 1)
    ])
    expect(snapshot[:balance_as_of]).to eq(150.00)
    expect(snapshot[:status_as_of]).to eq("active")
  end

  it "reports zero balance before the loan start date" do
    snapshot = described_class.new(company, as_of_date: Date.new(2025, 12, 31)).loans.first

    expect(snapshot[:transactions]).to be_empty
    expect(snapshot[:balance_as_of]).to eq(0)
  end
  it "uses the opening balance when a scoped loan has no transactions" do
    loan.loan_transactions.delete_all
    loan.update!(opening_balance: 125)
    snapshot = described_class.new(company, as_of_date: Date.new(2026, 3, 1), pay_period_scope: PayPeriod.client_finished).loans.sole
    expect(snapshot[:balance_as_of]).to eq(125)
    expect(snapshot[:transactions]).to be_empty
  end

  it "replays a scoped ledger from its first recorded entry when an addition is backdated" do
    loan.loan_transactions.delete_all
    # The first recorded entry (Jan 20) is not the earliest-dated one (Jan 10),
    # so a date-ordered start would replay from 150 and report 175.
    loan.update!(opening_balance: 200, current_balance: 225)
    [
      [ "payment", 50, 200, 150, Date.new(2026, 1, 20) ],
      [ "addition", 100, 150, 250, Date.new(2026, 1, 10) ],
      [ "payment", 25, 250, 225, Date.new(2026, 2, 1) ]
    ].each do |type, amount, before, after, date|
      loan.loan_transactions.create!(transaction_type: type, amount: amount, balance_before: before, balance_after: after, transaction_date: date)
    end

    scoped = described_class.new(company, as_of_date: Date.new(2026, 3, 1), pay_period_scope: PayPeriod.client_finished).loans.sole
    unscoped = described_class.new(company, as_of_date: Date.new(2026, 3, 1)).loans.sole
    expect(scoped[:balance_as_of]).to eq(225)
    expect(unscoped[:balance_as_of]).to eq(225)
  end
end
