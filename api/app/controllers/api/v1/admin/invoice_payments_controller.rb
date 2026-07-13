# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoicePaymentsController < BaseController
        before_action :set_invoice
        before_action :set_payment, only: :reverse

        def create
          payment = InvoicePaymentService.record!(
            invoice: @invoice,
            actor: current_user,
            amount: params.require(:amount),
            received_on: params.require(:received_on),
            payment_method: params.require(:payment_method),
            currency: params[:currency],
            reference_number: params[:reference_number],
            notes: params[:notes]
          )

          render json: {
            payment_id: payment.id,
            invoice: InvoicePayloadBuilder.call(@invoice.reload, detailed: true)
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError, Date::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def reverse
          InvoicePaymentService.reverse!(
            payment: @payment,
            actor: current_user,
            reason: params.require(:reason)
          )
          render json: { invoice: InvoicePayloadBuilder.call(@invoice.reload, detailed: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError, ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_invoice
          @invoice = Invoice.find_by(id: params[:invoice_id], organization_id: current_organization_id)
          return if @invoice

          render json: { error: "Invoice not found" }, status: :not_found
        end

        def set_payment
          @payment = @invoice.payments.find_by(id: params[:id])
          return if @payment

          render json: { error: "Invoice payment not found" }, status: :not_found
        end
      end
    end
  end
end
