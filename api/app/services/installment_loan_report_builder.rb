# frozen_string_literal: true

class InstallmentLoanReportBuilder
  attr_reader :company, :as_of_date

  def initialize(company, as_of_date: nil)
    @company = company
    @as_of_date = as_of_date || Date.current
  end

  def loans
    company.employee_loans
      .includes(:employee, loan_transactions: :pay_period)
      .order("employees.last_name ASC, employees.first_name ASC, employee_loans.name ASC")
      .map { |loan| loan_snapshot(loan) }
  end

  private

  def loan_snapshot(loan)
    all_transactions = loan.loan_transactions.chronological.to_a
    transactions = all_transactions.select { |txn| txn.transaction_date <= as_of_date }

    {
      loan: loan,
      employee: loan.employee,
      transactions: transactions,
      balance_as_of: balance_as_of(loan, all_transactions, transactions),
      status_as_of: status_as_of(loan, transactions)
    }
  end

  def balance_as_of(loan, all_transactions, transactions)
    return transactions.last.balance_after if transactions.any?
    return BigDecimal("0") if loan.start_date.present? && loan.start_date > as_of_date
    return all_transactions.first.balance_before if all_transactions.any?

    loan.current_balance
  end

  def status_as_of(loan, transactions)
    return "paid_off" if transactions.any? && transactions.last.balance_after.to_d.zero?
    return "active" if loan.paid_off_date.present? && loan.paid_off_date > as_of_date

    loan.status
  end
end
