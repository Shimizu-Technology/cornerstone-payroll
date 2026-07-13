# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceCreditNotesController < BaseController
        before_action :require_admin!
        before_action :set_invoice
        before_action :set_credit_note, only: :void

        def create
          credit = InvoiceCreditService.issue!(
            invoice: @invoice,
            actor: current_user,
            amount: params.require(:amount),
            issue_date: params.require(:issue_date),
            reason: params.require(:reason)
          )
          render json: {
            credit_note_id: credit.id,
            invoice: InvoicePayloadBuilder.call(@invoice.reload, detailed: true)
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError, ActionController::ParameterMissing, Date::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def void
          InvoiceCreditService.void!(
            credit_note: @credit_note,
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

        def set_credit_note
          @credit_note = @invoice.credit_notes.find_by(id: params[:id])
          return if @credit_note

          render json: { error: "Invoice credit note not found" }, status: :not_found
        end
      end
    end
  end
end
