# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe InstallmentLoanReportPdfGenerator do
  it "passes the requested as_of_date to the installment loan report builder" do
    company = build_stubbed(:company)
    as_of_date = Date.new(2026, 3, 1)
    builder = instance_double(InstallmentLoanReportBuilder, loans: [])

    expect(InstallmentLoanReportBuilder).to receive(:new)
      .with(company, as_of_date: as_of_date)
      .and_return(builder)

    bytes = described_class.new(company, as_of_date: as_of_date).generate
    reader = PDF::Reader.new(StringIO.new(bytes))
    expect(reader.page_count).to eq(1)
    expect(reader.pages.first.text).to include("No employee loans found.", "Employee Installment Loan Report", "Mar 01, 2026", "CONFIDENTIAL")
  end
  it "renders a populated transaction table using balances and transactions as of the requested date" do
    company = create(:company)
    employee = create(:employee, company: company)
    loan = EmployeeLoan.create!(company: company, employee: employee, name: "Synthetic Tool Advance",
      original_amount: 200, current_balance: 75, payment_amount: 25,
      start_date: Date.new(2026, 1, 1), status: "active")
    [ [ "addition", 200, 0, 200, Date.new(2026, 1, 1) ],
      [ "payment", 50, 200, 150, Date.new(2026, 2, 1) ],
      [ "payment", 75, 150, 75, Date.new(2026, 4, 1) ] ].each do |type, amount, before, after, date|
      loan.loan_transactions.create!(transaction_type: type, amount: amount,
        balance_before: before, balance_after: after, transaction_date: date)
    end
    bytes = described_class.new(company, as_of_date: Date.new(2026, 3, 1)).generate
    reader = PDF::Reader.new(StringIO.new(bytes))
    text = reader.pages.map(&:text).join(" ").gsub(/\s+/, " ")
    expect(text).to include(employee.full_name, "Synthetic Tool Advance", "Balance as of 03/01/2026: $150.00")
    expect(text).to include("01/01/2026", "02/01/2026", "Beginning Balance", "Ending Balance", "$200.00", "$150.00", "CONFIDENTIAL")
    expect(text).not_to include("04/01/2026", "No employee loans found.")
  end
end
