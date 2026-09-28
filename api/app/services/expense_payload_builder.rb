# frozen_string_literal: true

class ExpensePayloadBuilder
  def self.call(expense, detailed: false)
    payload = {
      id: expense.id,
      organization_id: expense.organization_id,
      finance_book_id: expense.finance_book_id,
      expense_vendor_id: expense.expense_vendor_id,
      vendor_name: expense.expense_vendor.name,
      reference_number: expense.reference_number,
      source_key: expense.source_key,
      category: expense.category,
      description: expense.description,
      expense_on: expense.expense_on,
      due_on: expense.due_on,
      total_amount: expense.total_amount.to_s("F"),
      amount_paid: expense.amount_paid.to_s("F"),
      balance_due: expense.balance_due.to_s("F"),
      payment_status: expense.payment_status,
      currency: expense.currency,
      voided_at: expense.voided_at,
      void_reason: expense.void_reason,
      artifact_count: expense.expense_artifacts.size,
      created_at: expense.created_at,
      updated_at: expense.updated_at
    }
    return payload unless detailed

    payload.merge(
      payments: expense.expense_payments.chronological.map do |payment|
        payment.as_json(only: %i[id amount paid_on payment_method reference_number notes reversed_at reversal_reason
                                 recorded_by_id created_at])
      end,
      artifacts: expense.expense_artifacts.order(:id).map do |artifact|
        artifact.as_json(only: %i[id filename content_type byte_size sha256 created_at])
      end
    )
  end
end
