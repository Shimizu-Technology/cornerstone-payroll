# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceReceivablesController < BaseController
        def show
          render json: InvoiceReceivablesSummary.new(
            organization: current_user.organization,
            billing_profile_id: params[:billing_profile_id],
            as_of: params[:as_of].present? ? Date.iso8601(params[:as_of]) : Date.current
          ).call
        rescue Date::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def statement
          recipient = InvoiceRecipient.find_by(id: params[:recipient_id], organization_id: current_organization_id)
          unless recipient
            render json: { error: "Invoice recipient not found" }, status: :not_found
            return
          end

          scope = Invoice.where(organization_id: current_organization_id, invoice_recipient: recipient)
            .includes(:invoice_billing_profile, :line_items, :payments, :credit_notes, :artifacts)
            .recent
          scope = scope.where(invoice_billing_profile_id: params[:billing_profile_id]) if params[:billing_profile_id].present?
          receivables = scope.reject { |invoice| invoice.draft? || invoice.voided? || invoice.uncollectible? }

          render json: {
            recipient: { id: recipient.id, name: recipient.name, email: recipient.email, address: recipient.address },
            invoices: scope.map { |invoice| InvoicePayloadBuilder.call(invoice) },
            outstanding: receivables.sum { |invoice| invoice.balance_due }.round(2).to_f
          }
        end
      end
    end
  end
end
