# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceRecipientsController < BaseController
        before_action :require_admin!

        before_action :set_recipient, only: [ :show, :update, :destroy ]

        def index
          recipients = InvoiceRecipient
            .where(organization_id: current_organization_id)
            .alphabetical

          recipients = recipients.active if ActiveModel::Type::Boolean.new.cast(params[:active])

          render json: {
            invoice_recipients: recipients.map { |recipient| recipient_payload(recipient) }
          }
        end

        def show
          render json: { invoice_recipient: recipient_payload(@recipient) }
        end

        def create
          recipient = InvoiceRecipient.new(recipient_attributes)
          recipient.organization_id = current_organization_id

          if recipient.save
            render json: { invoice_recipient: recipient_payload(recipient) }, status: :created
          else
            render json: { errors: recipient.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          if @recipient.update(recipient_attributes)
            render json: { invoice_recipient: recipient_payload(@recipient) }
          else
            render json: { errors: @recipient.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          if @recipient.invoices.exists?
            @recipient.update!(active: false)
            render json: { invoice_recipient: recipient_payload(@recipient), message: "Invoice recipient archived" }
          else
            @recipient.destroy!
            render json: { message: "Invoice recipient deleted" }
          end
        end

        private

        def set_recipient
          @recipient = InvoiceRecipient.find_by(id: params[:id], organization_id: current_organization_id)
          return if @recipient

          render json: { error: "Invoice recipient not found" }, status: :not_found
        end

        def recipient_attributes
          params.require(:invoice_recipient).permit(
            :name,
            :email,
            :address,
            :default_rate,
            :invoice_prefix,
            :payment_terms,
            :template_type,
            :notes,
            :active
          )
        end

        def recipient_payload(recipient)
          {
            id: recipient.id,
            organization_id: recipient.organization_id,
            company_id: recipient.company_id,
            name: recipient.name,
            email: recipient.email,
            address: recipient.address,
            default_rate: recipient.default_rate&.to_f,
            invoice_prefix: recipient.invoice_prefix,
            payment_terms: recipient.payment_terms,
            template_type: recipient.template_type,
            notes: recipient.notes,
            active: recipient.active,
            created_at: recipient.created_at,
            updated_at: recipient.updated_at
          }
        end
      end
    end
  end
end
