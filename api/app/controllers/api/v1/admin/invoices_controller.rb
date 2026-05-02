# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoicesController < BaseController
        before_action :set_invoice, only: [ :show, :update, :destroy, :update_status, :preview_pdf, :generate_pdf ]

        def index
          invoices = Invoice
            .where(company_id: current_company_id)
            .includes(:invoice_recipient, :line_items, :created_by, :updated_by)
            .recent

          invoices = invoices.where(status: params[:status]) if params[:status].present?

          render json: {
            invoices: invoices.map { |invoice| invoice_payload(invoice) }
          }
        end

        def show
          render json: { invoice: invoice_payload(@invoice, detailed: true) }
        end

        def create
          invoice = Invoice.new(invoice_attributes)
          invoice.company_id = current_company_id
          invoice.created_by = current_user
          invoice.updated_by = current_user
          assign_line_items!(invoice)

          if invoice.save
            render json: { invoice: invoice_payload(invoice.reload, detailed: true) }, status: :created
          else
            render json: { errors: invoice.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: [ "Invoice number has already been taken" ] }, status: :unprocessable_entity
        end

        def update
          if @invoice.generated_or_later? && params[:mark_draft] != "true"
            render json: { error: "Cannot modify a finalized invoice without marking it as draft" }, status: :unprocessable_entity
            return
          end
          if @invoice.generated_or_later? && params[:mark_draft] == "true" && !draft_transition_allowed?
            render json: { error: "Cannot mark #{@invoice.status} invoice as draft" }, status: :unprocessable_entity
            return
          end

          @invoice.assign_attributes(invoice_attributes)
          @invoice.updated_by = current_user
          if @invoice.generated_or_later? && params[:mark_draft] == "true"
            @invoice.status = "draft"
            @invoice.generated_at = nil
            @invoice.sent_at = nil
            @invoice.paid_at = nil
            @invoice.voided_at = nil
            @invoice.archived_at = nil
          end
          assign_line_items!(@invoice)

          if @invoice.save
            render json: { invoice: invoice_payload(@invoice.reload, detailed: true) }
          else
            render json: { errors: @invoice.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: [ "Invoice number has already been taken" ] }, status: :unprocessable_entity
        end

        def destroy
          if @invoice.generated_or_later?
            render json: { error: "Finalized invoices cannot be deleted" }, status: :unprocessable_entity
            return
          end

          @invoice.destroy!
          render json: { message: "Invoice deleted" }
        end

        def update_status
          @invoice.update_status!(params.require(:status), actor: current_user)
          render json: { invoice: invoice_payload(@invoice.reload, detailed: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages.presence || [ e.message ] }, status: :unprocessable_entity
        end

        def preview_pdf
          return unless ensure_line_items_for_pdf!

          generator = InvoicePdfGenerator.new(@invoice)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "inline"
        rescue Prawn::Errors::CannotFit => e
          render_pdf_generation_error(e)
        end

        def generate_pdf
          return unless ensure_line_items_for_pdf!

          generator = InvoicePdfGenerator.new(@invoice)
          pdf_content = generator.generate

          @invoice.mark_generated!(actor: current_user) if @invoice.draft?
          send_data pdf_content,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages.presence || [ e.message ] }, status: :unprocessable_entity
        rescue Prawn::Errors::CannotFit => e
          render_pdf_generation_error(e)
        end

        private

        def set_invoice
          @invoice = Invoice
            .includes(:invoice_recipient, :line_items, :created_by, :updated_by)
            .find_by(id: params[:id], company_id: current_company_id)
          return if @invoice

          render json: { error: "Invoice not found" }, status: :not_found
        end

        def invoice_attributes
          raw = params.require(:invoice).permit(
            :invoice_recipient_id,
            :invoice_number,
            :invoice_date,
            :service_period_start,
            :service_period_end,
            :notes,
            :payment_terms,
            :email_subject,
            :email_body
          )

          if raw[:invoice_recipient_id].present?
            recipient = InvoiceRecipient.find_by(id: raw[:invoice_recipient_id], company_id: current_company_id)
            raise ArgumentError, "Invoice recipient not found" unless recipient
            if inactive_new_recipient?(recipient)
              raise ArgumentError, "Invoice recipient is archived"
            end
          end

          raw
        end

        def inactive_new_recipient?(recipient)
          return false if recipient.active?
          return false if defined?(@invoice) && @invoice&.invoice_recipient_id == recipient.id

          true
        end

        def draft_transition_allowed?
          Invoice::ALLOWED_TRANSITIONS.fetch(@invoice.status, []).include?("draft")
        end

        def line_item_params
          Array(params.dig(:invoice, :line_items)).map do |item|
            item_hash = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item
            ActionController::Parameters.new(item_hash).permit(
              :id,
              :description,
              :quantity,
              :rate,
              :service_date,
              :position,
              :_destroy
            )
          end
        end

        def assign_line_items!(invoice)
          return unless params.dig(:invoice, :line_items)

          existing_by_id = invoice.line_items.index_by { |item| item.id&.to_s }
          kept_ids = []

          line_item_params.each_with_index do |attrs, index|
            if ActiveModel::Type::Boolean.new.cast(attrs[:_destroy])
              existing_by_id[attrs[:id].to_s]&.mark_for_destruction if attrs[:id].present?
              next
            end

            item = attrs[:id].present? ? existing_by_id[attrs[:id].to_s] : nil
            item ||= invoice.line_items.build
            item.assign_attributes(
              description: attrs[:description],
              quantity: attrs[:quantity].presence || 0,
              rate: attrs[:rate].presence || 0,
              service_date: attrs[:service_date].presence,
              position: attrs[:position].presence || index
            )
            kept_ids << item.id if item.persisted?
          end

          invoice.line_items.each do |item|
            next if item.new_record?
            next if kept_ids.include?(item.id)
            next if item.marked_for_destruction?

            item.mark_for_destruction
          end
        end

        def ensure_line_items_for_pdf!
          return true if @invoice.line_items.any?

          render json: { errors: [ "Line items must include at least one item" ] }, status: :unprocessable_entity
          false
        end

        def render_pdf_generation_error(error)
          Rails.logger.warn("Invoice PDF generation failed: #{error.class}: #{error.message}")
          render json: { error: "Unable to generate invoice PDF" }, status: :unprocessable_entity
        end

        def invoice_payload(invoice, detailed: false)
          payload = {
            id: invoice.id,
            company_id: invoice.company_id,
            invoice_recipient_id: invoice.invoice_recipient_id,
            recipient_name: invoice.invoice_recipient&.name,
            invoice_number: invoice.invoice_number,
            invoice_date: invoice.invoice_date,
            service_period_start: invoice.service_period_start,
            service_period_end: invoice.service_period_end,
            total_amount: invoice.total_amount.to_f,
            status: invoice.status,
            generated_at: invoice.generated_at,
            sent_at: invoice.sent_at,
            paid_at: invoice.paid_at,
            voided_at: invoice.voided_at,
            archived_at: invoice.archived_at,
            created_by_id: invoice.created_by_id,
            created_by_name: invoice.created_by&.name,
            updated_by_id: invoice.updated_by_id,
            updated_by_name: invoice.updated_by&.name,
            line_item_count: invoice.line_items.size,
            created_at: invoice.created_at,
            updated_at: invoice.updated_at
          }

          if detailed
            payload.merge!(
              notes: invoice.notes,
              payment_terms: invoice.payment_terms,
              email_subject: invoice.email_subject,
              email_body: invoice.email_body,
              invoice_recipient: recipient_payload(invoice.invoice_recipient),
              line_items: invoice.line_items.map { |item| line_item_payload(item) }
            )
          end

          payload
        end

        def recipient_payload(recipient)
          return nil unless recipient

          {
            id: recipient.id,
            company_id: recipient.company_id,
            name: recipient.name,
            email: recipient.email,
            address: recipient.address,
            default_rate: recipient.default_rate&.to_f,
            invoice_prefix: recipient.invoice_prefix,
            payment_terms: recipient.payment_terms,
            template_type: recipient.template_type,
            notes: recipient.notes,
            active: recipient.active
          }
        end

        def line_item_payload(item)
          {
            id: item.id,
            description: item.description,
            quantity: item.quantity.to_f,
            rate: item.rate.to_f,
            amount: item.amount.to_f,
            service_date: item.service_date,
            position: item.position,
            created_at: item.created_at,
            updated_at: item.updated_at
          }
        end
      end
    end
  end
end
