# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceChatSessionsController < BaseController
        before_action :set_session, only: [ :show, :update, :destroy, :message, :confirm, :restore, :restore_preview ]

        def index
          sessions = InvoiceChatSession
            .where(company_id: current_company_id)
            .includes(:invoice_recipient, :invoice)
            .recent
          sessions = sessions.where(archived: false) unless include_archived_sessions?
          message_counts = InvoiceChatMessage
            .where(invoice_chat_session_id: sessions.map(&:id))
            .group(:invoice_chat_session_id)
            .count

          render json: {
            invoice_chat_sessions: sessions.map do |session|
              session_payload(session, message_count: message_counts[session.id].to_i)
            end
          }
        end

        def show
          render json: { invoice_chat_session: session_payload(@session, detailed: true) }
        end

        def create
          session = InvoiceChatSession.new(session_attributes)
          session.company_id = current_company_id
          session.created_by = current_user
          session.updated_by = current_user

          if session.save
            render json: { invoice_chat_session: session_payload(session.reload, detailed: true) }, status: :created
          else
            render json: { errors: session.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update
          if @session.update(session_attributes.merge(updated_by: current_user))
            render json: { invoice_chat_session: session_payload(@session.reload, detailed: true) }
          else
            render json: { errors: @session.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def destroy
          @session.archive!(actor: current_user)
          render json: { invoice_chat_session: session_payload(@session.reload, detailed: true) }
        end

        def restore
          @session.update!(archived: false, status: "active", updated_by: current_user)
          render json: { invoice_chat_session: session_payload(@session.reload, detailed: true) }
        end

        def message
          image_urls = []
          attachments_persisted = false
          content = params.require(:content).to_s.strip
          if content.blank?
            render json: { error: "Message cannot be blank" }, status: :unprocessable_entity
            return
          end

          image_urls = upload_message_attachments
          preview = InvoiceAiPreviewService.new(
            company: current_company,
            user: current_user,
            session: @session,
            message: content,
            image_urls: image_urls
          ).call
          user_message = nil
          assistant_message = nil

          InvoiceChatSession.transaction do
            @session.lock!
            raise ArgumentError, "Cannot send messages to an archived session" if @session.archived? || @session.status == "archived"
            @session.status = "active" if @session.status == "invoice_created"

            user_message = @session.messages.create!(role: "user", content: content, image_urls: image_urls)
            version = @session.store_preview!(preview, actor: current_user)
            assistant_message = @session.messages.create!(
              role: "assistant",
              content: preview["message"],
              preview: preview,
              preview_version: version,
              has_preview: preview["status"] == "preview"
            )
          end
          attachments_persisted = true

          render json: {
            invoice_chat_session: session_payload(@session.reload, detailed: true),
            user_message: message_payload(user_message),
            assistant_message: message_payload(assistant_message)
          }
        rescue ArgumentError => e
          cleanup_uploaded_attachments(image_urls)
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          cleanup_uploaded_attachments(image_urls)
          render json: { errors: e.record.errors.full_messages.presence || [ e.message ] }, status: :unprocessable_entity
        rescue StandardError
          cleanup_uploaded_attachments(image_urls) unless attachments_persisted
          raise
        end

        def confirm
          invoice = nil
          created_invoice = false
          InvoiceChatSession.transaction do
            @session.lock!
            raise ArgumentError, "Cannot confirm an archived session" if @session.archived? || @session.status == "archived"

            if current_preview_already_created?
              invoice = Invoice.find_by(id: @session.invoice_id, organization_id: current_organization_id)
              raise ArgumentError, "Invoice already created for this preview but could not be found" unless invoice
              next
            end

            preview = @session.current_preview
            invoice = invoice_from_preview!(preview)
            @session.update!(
              invoice: invoice,
              invoice_recipient_id: invoice.invoice_recipient_id,
              status: "active",
              updated_by: current_user
            )
            created_invoice = true
            @session.messages.create!(
              role: "assistant",
              content: "Created draft invoice #{invoice.invoice_number}. You can keep using this chat for the next invoice.",
              preview: preview,
              preview_version: @session.current_preview_version,
              has_preview: true
            )
          end

          render json: {
            invoice: invoice_payload(invoice.reload),
            invoice_chat_session: session_payload(@session.reload, detailed: true)
          }, status: created_invoice ? :created : :ok
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages.presence || [ e.message ] }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: [ "Invoice number has already been taken" ] }, status: :unprocessable_entity
        end

        def restore_preview
          message = @session.messages.find_by(id: params[:message_id])
          raise ArgumentError, "Preview message not found" unless message&.has_preview? && message.preview.present?

          InvoiceChatSession.transaction do
            @session.lock!
            raise ArgumentError, "Cannot restore previews on an archived session" if @session.archived? || @session.status == "archived"
            @session.status = "active" if @session.status == "invoice_created"

            version = @session.store_preview!(message.preview, actor: current_user)
            @session.messages.create!(
              role: "assistant",
              content: "Restored invoice preview version #{message.preview_version || version}.",
              preview: message.preview,
              preview_version: version,
              has_preview: true
            )
          end

          render json: { invoice_chat_session: session_payload(@session.reload, detailed: true) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages.presence || [ e.message ] }, status: :unprocessable_entity
        end

        private

        def include_archived_sessions?
          ActiveModel::Type::Boolean.new.cast(params[:include_archived])
        end

        def set_session
          @session = InvoiceChatSession
            .includes(:invoice_recipient, :invoice, :messages)
            .find_by(id: params[:id], company_id: current_company_id)
          return if @session

          render json: { error: "Invoice chat session not found" }, status: :not_found
        end

        def current_company
          @current_company ||= Company.find(current_company_id)
        end

        def session_attributes
          raw = params.fetch(:invoice_chat_session, ActionController::Parameters.new).permit(:title, :invoice_recipient_id)
          if raw[:invoice_recipient_id].present?
            recipient = InvoiceRecipient.find_by(id: raw[:invoice_recipient_id], company_id: current_company_id, active: true)
            raise ArgumentError, "Invoice recipient not found" unless recipient
          end
          raw
        end

        def invoice_from_preview!(preview)
          raise ArgumentError, "No invoice preview is ready to confirm" if preview.blank?

          recipient = recipient_from_preview!(preview)

          line_items = Array(preview["line_items"]).filter_map { |item| line_item_attributes_from_preview(item) }
          raise ArgumentError, "Preview must include at least one line item" if line_items.empty?

          invoice = Invoice.new(
            organization_id: current_organization_id,
            company_id: current_company_id,
            invoice_recipient: recipient,
            invoice_billing_profile: billing_profile_from_preview!(preview),
            invoice_date: parse_preview_date(preview["invoice_date"]) || Date.current,
            service_period_start: parse_preview_date(preview["service_period_start"]),
            service_period_end: parse_preview_date(preview["service_period_end"]),
            payment_terms: preview["payment_terms"].presence,
            notes: preview["notes"].presence,
            email_subject: preview["email_subject"].presence,
            email_body: preview["email_body"].presence,
            created_by: current_user,
            updated_by: current_user
          )
          line_items.each_with_index do |attrs, index|
            invoice.line_items.build(attrs.merge(position: index))
          end
          invoice.save!
          invoice
        end

        def current_preview_already_created?
          return false if @session.invoice_id.blank?

          @session.messages.where(
            role: "assistant",
            has_preview: true,
            preview_version: @session.current_preview_version
          ).where("content LIKE ?", "Created draft invoice%").exists?
        end

        def recipient_from_preview!(preview)
          if preview["invoice_recipient_id"].present?
            recipient = InvoiceRecipient.find_by(
              id: preview["invoice_recipient_id"],
              organization_id: current_organization_id,
              active: true
            )
            raise ArgumentError, "Invoice recipient not found" unless recipient

            return recipient
          end

          attrs = new_recipient_attributes_from_preview(preview["new_recipient"])
          raise ArgumentError, "Invoice recipient not found" if attrs.blank?

          InvoiceRecipient.create!(attrs.merge(organization_id: current_organization_id, company_id: current_company_id, active: true))
        end

        def billing_profile_from_preview!(preview)
          if preview["invoice_billing_profile_id"].present?
            profile = InvoiceBillingProfile.find_by(
              id: preview["invoice_billing_profile_id"],
              organization_id: current_organization_id,
              active: true
            )
            raise ArgumentError, "Invoice billing profile not found" unless profile

            return profile
          end

          InvoiceBillingProfile.ensure_default_for!(current_organization)
        end

        def new_recipient_attributes_from_preview(raw)
          return nil if raw.blank?

          name = raw["name"].to_s.strip.presence
          return nil unless name

          {
            name: name,
            email: raw["email"].to_s.strip.presence,
            address: raw["address"].to_s.strip.presence,
            default_rate: optional_decimal_from_preview(raw["default_rate"]),
            invoice_prefix: raw["invoice_prefix"].to_s.strip.presence,
            payment_terms: raw["payment_terms"].to_s.strip.presence,
            template_type: %w[standard hourly project tuition].include?(raw["template_type"].to_s) ? raw["template_type"].to_s : "standard",
            notes: raw["notes"].to_s.strip.presence
          }
        end

        def line_item_attributes_from_preview(item)
          description = item["description"].to_s.strip
          quantity = BigDecimal(item["quantity"].to_s)
          rate = BigDecimal(item["rate"].to_s)
          return nil if description.blank? || quantity <= 0 || rate < 0

          {
            description: description,
            quantity: quantity,
            rate: rate,
            service_date: parse_preview_date(item["service_date"])
          }
        rescue ArgumentError
          nil
        end

        def optional_decimal_from_preview(value)
          return nil if value.blank?

          decimal = BigDecimal(value.to_s)
          decimal.negative? ? nil : decimal
        rescue ArgumentError
          nil
        end

        def parse_preview_date(value)
          return nil if value.blank?

          Date.iso8601(value.to_s)
        rescue Date::Error
          nil
        end

        def upload_message_attachments
          uploaded = []
          Array(params[:images]).compact.each do |file|
            uploaded << InvoiceAiAttachmentStorageService.upload(
              file,
              company_id: current_company_id,
              session_id: @session.id
            )
          end
          uploaded
        rescue ArgumentError
          cleanup_uploaded_attachments(uploaded)
          raise
        end

        def cleanup_uploaded_attachments(image_urls)
          Array(image_urls).compact_blank.each do |reference|
            R2StorageService.new.delete(reference)
          rescue R2StorageService::UploadError => e
            Rails.logger.warn("Invoice AI attachment cleanup failed: #{e.class}: #{e.message}")
          end
        end

        def session_payload(session, detailed: false, message_count: nil)
          payload = {
            id: session.id,
            company_id: session.company_id,
            invoice_recipient_id: session.invoice_recipient_id,
            invoice_id: session.invoice_id,
            title: session.title,
            status: session.status,
            current_preview: session.current_preview,
            current_preview_version: session.current_preview_version,
            archived: session.archived,
            recipient_name: session.invoice_recipient&.name,
            invoice_number: session.invoice&.invoice_number,
            message_count: message_count.nil? ? session.messages.size : message_count,
            created_at: session.created_at,
            updated_at: session.updated_at
          }
          payload[:messages] = session.messages.map { |message| message_payload(message) } if detailed
          payload
        end

        def message_payload(message)
          {
            id: message.id,
            role: message.role,
            content: message.content,
            image_urls: message.image_urls,
            preview: message.preview,
            preview_version: message.preview_version,
            has_preview: message.has_preview,
            created_at: message.created_at
          }
        end

        def invoice_payload(invoice)
          {
            id: invoice.id,
            organization_id: invoice.organization_id,
            company_id: invoice.company_id,
            invoice_recipient_id: invoice.invoice_recipient_id,
            invoice_billing_profile_id: invoice.invoice_billing_profile_id,
            recipient_name: invoice.invoice_recipient&.name,
            billing_profile_name: invoice.invoice_billing_profile&.name,
            invoice_number: invoice.invoice_number,
            invoice_date: invoice.invoice_date,
            service_period_start: invoice.service_period_start,
            service_period_end: invoice.service_period_end,
            total_amount: invoice.total_amount.to_f,
            status: invoice.status,
            notes: invoice.notes,
            payment_terms: invoice.payment_terms,
            email_subject: invoice.email_subject,
            email_body: invoice.email_body,
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
            invoice_recipient: recipient_payload(invoice.invoice_recipient),
            invoice_billing_profile: billing_profile_payload(invoice.invoice_billing_profile),
            line_items: invoice.line_items.map { |item| invoice_line_item_payload(item) },
            created_at: invoice.created_at,
            updated_at: invoice.updated_at
          }
        end

        def recipient_payload(recipient)
          return nil unless recipient

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
            active: recipient.active
          }
        end

        def billing_profile_payload(profile)
          return nil unless profile

          {
            id: profile.id,
            organization_id: profile.organization_id,
            name: profile.name,
            legal_name: profile.legal_name,
            website: profile.website,
            phone: profile.phone,
            email: profile.email,
            address: profile.address,
            payment_instructions: profile.payment_instructions,
            default_payment_terms: profile.default_payment_terms,
            invoice_prefix: profile.invoice_prefix,
            remit_to: profile.remit_to,
            footer_note: profile.footer_note,
            active: profile.active,
            is_default: profile.is_default
          }
        end

        def invoice_line_item_payload(item)
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
