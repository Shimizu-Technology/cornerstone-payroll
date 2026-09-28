# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ExpensePaymentsController < BaseController
        before_action :require_admin!

        def create
          expense = scoped_expense
          payment = ExpensePaymentService.record!(
            expense: expense, actor: current_user, amount: params.require(:amount),
            paid_on: Date.iso8601(params.require(:paid_on)), payment_method: params.require(:payment_method),
            reference_number: params[:reference_number], notes: params[:notes]
          )
          render json: { payment_id: payment.id, expense: ExpensePayloadBuilder.call(expense.reload, detailed: true) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError, Date::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def reverse
          expense = scoped_expense
          payment = expense.expense_payments.find(params[:id])
          ExpensePaymentService.reverse!(payment: payment, actor: current_user, reason: params.require(:reason))
          render json: { expense: ExpensePayloadBuilder.call(expense.reload, detailed: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def scoped_expense
          Expense.find_by!(id: params[:expense_id], organization_id: current_organization_id)
        end
      end
    end
  end
end
