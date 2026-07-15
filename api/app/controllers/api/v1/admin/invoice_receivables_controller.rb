# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceReceivablesController < BaseController
        before_action :require_admin!

        def show
          render json: InvoiceReceivablesSummary.new(
            organization: current_organization,
            billing_profile_id: params[:billing_profile_id],
            as_of: params[:as_of].present? ? Date.iso8601(params[:as_of]) : Date.current
          ).call
        rescue Date::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def statement
          recipient = InvoiceRecipient.find_by(id: params[:recipient_id], organization: current_organization)
          unless recipient
            render json: { error: "Invoice recipient not found" }, status: :not_found
            return
          end

          scope = Invoice.where(organization: current_organization, invoice_recipient: recipient)
            .includes(:invoice_billing_profile, :line_items, :payments, :credit_notes, :artifacts, :deliveries)
            .recent
          scope = scope.where(invoice_billing_profile_id: params[:billing_profile_id]) if params[:billing_profile_id].present?
          receivables = scope.reject { |invoice| invoice.draft? || invoice.voided? || invoice.uncollectible? }

          render json: {
            recipient: { id: recipient.id, name: recipient.name, email: recipient.email, address: recipient.address },
            invoices: receivables.map { |invoice| InvoicePayloadBuilder.call(invoice) },
            outstanding: receivables.sum { |invoice| invoice.balance_due }.round(2).to_f
          }
        end
      end
    end
  end
end
