# frozen_string_literal: true

class FinanceOverviewSummary
  def initialize(finance_book:, as_of: Date.current)
    @finance_book = finance_book
    @as_of = as_of
  end

  def call
    totals = Hash.new { |hash, currency| hash[currency] = empty_totals }

    Invoice.where(finance_book: @finance_book).includes(:payments, :credit_notes).find_in_batches(batch_size: 200) do |batch|
      batch.each do |invoice|
        row = totals[invoice.currency]
        row[:payments_received] += invoice.amount_paid
        next if invoice.draft? || invoice.voided? || invoice.uncollectible? || invoice.balance_due.zero?

        row[:receivables] += invoice.balance_due
        row[:open_invoice_count] += 1
        if invoice.due_date.present? && invoice.due_date < @as_of
          row[:overdue_receivables] += invoice.balance_due
          row[:overdue_invoice_count] += 1
        end
      end
    end

    Expense.where(finance_book: @finance_book).includes(:expense_payments).find_in_batches(batch_size: 200) do |batch|
      batch.each do |expense|
        next if expense.voided?

        row = totals[expense.currency]
        row[:payments_made] += expense.amount_paid
        next if expense.balance_due.zero?

        row[:payables] += expense.balance_due
        row[:open_expense_count] += 1
        if expense.due_on.present? && expense.due_on < @as_of
          row[:overdue_payables] += expense.balance_due
          row[:overdue_expense_count] += 1
        end
      end
    end

    { finance_book_id: @finance_book.id, as_of: @as_of,
      currencies: totals.sort.map { |currency, values| { currency: currency }.merge(format_values(values)) } }
  end

  private

  def empty_totals
    {
      receivables: 0.to_d, overdue_receivables: 0.to_d, payments_received: 0.to_d,
      payables: 0.to_d, overdue_payables: 0.to_d, payments_made: 0.to_d,
      open_invoice_count: 0, overdue_invoice_count: 0, open_expense_count: 0, overdue_expense_count: 0
    }
  end

  def format_values(values)
    values.transform_values { |value| value.is_a?(BigDecimal) ? value.round(2).to_s("F") : value }
  end
end
