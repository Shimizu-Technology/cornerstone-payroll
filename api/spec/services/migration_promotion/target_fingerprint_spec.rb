# frozen_string_literal: true

require "rails_helper"

RSpec.describe MigrationPromotion::TargetFingerprint do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }

  it "changes when financial state that promotion replaces changes" do
    original = described_class.call(company)
    EmployeeYtdTotal.create!(employee: employee, year: 2026, gross_pay: 100)
    after_ytd = described_class.call(company)

    loan = EmployeeLoan.create!(
      company: company,
      employee: employee,
      name: "Uniform deduction",
      tracking_mode: "recurring_no_balance",
      principal_amount_known: false,
      status: "active",
      payment_amount: 25,
      first_deduction_date: Date.new(2026, 9, 10)
    )
    before_transaction = described_class.call(company)
    loan.loan_transactions.create!(
      transaction_type: "payment",
      amount: 25,
      transaction_date: Date.new(2026, 9, 10),
      source: "manual"
    )

    expect(after_ytd).not_to eq(original)
    expect(described_class.call(company)).not_to eq(before_transaction)
  end

  it "changes when existing employee setup is edited in place" do
    employee
    original = described_class.call(company)

    employee.update!(pay_rate: employee.pay_rate + 1)

    expect(described_class.call(company)).not_to eq(original)
  end

  it "changes when an employee is excluded from an empty draft" do
    pay_period = create(:pay_period, company: company)
    employee
    original = described_class.call(company)

    PayPeriodExcludedEmployee.create!(
      pay_period: pay_period,
      employee: employee,
      reason: "Not scheduled"
    )

    expect(described_class.call(company)).not_to eq(original)
  end
end
