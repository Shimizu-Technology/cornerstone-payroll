# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoicesController < BaseController
        before_action :require_admin!
        before_action :set_invoice, only: %i[
          show update destroy update_status preview_pdf generate_pdf issue download_artifact record_delivery
        ]

        def index
          invoices = invoice_scope.recent
          invoices = invoices.where(invoice_billing_profile_id: params[:billing_profile_id]) if params[:billing_profile_id].present?
          invoices = invoices.where(invoice_recipient_id: params[:recipient_id]) if params[:recipient_id].present?
          invoices = invoices.where(origin: params[:origin]) if params[:origin].present?
          invoices = invoices.where(archived: ActiveModel::Type::Boolean.new.cast(params[:archived])) if params.key?(:archived)

          rows = invoices.map { |invoice| InvoicePayloadBuilder.call(invoice) }
          rows.select! { |row| row[:status] == params[:status] } if params[:status].present?

          render json: { invoices: rows }
        end

        def show
          render json: { invoice: InvoicePayloadBuilder.call(@invoice, detailed: true) }
        end

        def create
          invoice = Invoice.new(invoice_attributes)
          invoice.organization_id = current_organization_id
          invoice.company = optional_source_company
          invoice.created_by = current_user
          invoice.updated_by = current_user
          assign_line_items!(invoice)

          Invoice.transaction do
            invoice.save!
            InvoiceEvent.record!(invoice: invoice, event_type: "draft_created", actor: current_user)
          end

          render json: { invoice: InvoicePayloadBuilder.call(invoice.reload, detailed: true) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: [ "Invoice number has already been taken" ] }, status: :unprocessable_entity
        end

        def update
          Invoice.transaction do
            @invoice.lock!
            raise ArgumentError, "Issued invoice financial content is immutable" unless @invoice.draft?

            @invoice.assign_attributes(invoice_attributes)
            @invoice.company = optional_source_company if params.dig(:invoice, :company_id).present?
            @invoice.updated_by = current_user
            assign_line_items!(@invoice)
            @invoice.save!
            InvoiceEvent.record!(invoice: @invoice, event_type: "draft_updated", actor: current_user)
          end

          render json: { invoice: InvoicePayloadBuilder.call(@invoice.reload, detailed: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: [ "Invoice number has already been taken" ] }, status: :unprocessable_entity
        end

        def destroy
          Invoice.transaction do
            @invoice.lock!
            raise ArgumentError, "Issued invoices cannot be deleted" unless @invoice.draft?

            @invoice.update!(archived: true, archived_at: Time.current, updated_by: current_user)
            InvoiceEvent.record!(invoice: @invoice, event_type: "draft_deleted", actor: current_user)
          end

          render json: { message: "Draft invoice removed from active view" }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def issue
          artifact = InvoiceArtifactStorageService.new.issue_native!(invoice: @invoice, actor: current_user)
          render json: {
            invoice: InvoicePayloadBuilder.call(@invoice.reload, detailed: true),
            artifact_id: artifact.id
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue R2StorageService::UploadError, Prawn::Errors::CannotFit => e
          Rails.logger.warn("Invoice issue failed: #{e.class}: #{e.message}")
          render json: { error: "Unable to issue and store the invoice artifact" }, status: :unprocessable_entity
        end

        def import
          invoice = build_imported_invoice
          issued_at = import_issued_at
          delivery_attributes = import_delivery_attributes
          invoice.save!
          artifact = InvoiceArtifactStorageService.new.import_original!(
            invoice: invoice,
            actor: current_user,
            file: params[:file],
            issued_at: issued_at
          )
          create_import_delivery!(invoice, artifact, delivery_attributes)

          render json: { invoice: InvoicePayloadBuilder.call(invoice.reload, detailed: true) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          invoice&.destroy if invoice&.persisted? && invoice.draft? && invoice.events.empty? && invoice.artifacts.empty?
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError, Date::Error, Time::Error => e
          invoice&.destroy if invoice&.persisted? && invoice.draft? && invoice.events.empty? && invoice.artifacts.empty?
          render json: { error: e.message }, status: :unprocessable_entity
        rescue R2StorageService::UploadError => e
          invoice&.destroy if invoice&.persisted? && invoice.draft? && invoice.events.empty? && invoice.artifacts.empty?
          Rails.logger.warn("Invoice import failed: #{e.class}: #{e.message}")
          render json: { error: "Unable to store the imported invoice" }, status: :unprocessable_entity
        end

        def update_status
          case params.require(:status).to_s
          when "open", "generated"
            InvoiceArtifactStorageService.new.issue_native!(invoice: @invoice, actor: current_user)
          when "voided"
            @invoice.void!(actor: current_user, reason: params[:reason].presence || "Voided by operator")
          when "uncollectible"
            @invoice.mark_uncollectible!(actor: current_user, reason: params[:reason].presence || "Marked uncollectible by operator")
          when "archived"
            @invoice.archive!(actor: current_user)
          when "restored"
            @invoice.restore!(actor: current_user)
          else
            @invoice.update_status!(params[:status], actor: current_user)
          end

          render json: { invoice: InvoicePayloadBuilder.call(@invoice.reload, detailed: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages.presence || [ e.message ] }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue R2StorageService::UploadError, Prawn::Errors::CannotFit
          render json: { error: "Unable to issue and store the invoice artifact" }, status: :unprocessable_entity
        end

        def preview_pdf
          if @invoice.draft?
            snapshot = @invoice.draft_snapshot(actor: current_user)
            generator = InvoicePdfGenerator.new(@invoice, snapshot: snapshot)
            send_data generator.generate, filename: generator.filename, type: "application/pdf", disposition: "inline"
          else
            send_primary_artifact(disposition: "inline")
          end
        rescue Prawn::Errors::CannotFit => e
          Rails.logger.warn("Invoice PDF generation failed: #{e.class}: #{e.message}")
          render json: { error: "Unable to generate invoice PDF" }, status: :unprocessable_entity
        end

        def generate_pdf
          InvoiceArtifactStorageService.new.issue_native!(invoice: @invoice, actor: current_user) if @invoice.draft?
          send_primary_artifact(disposition: "attachment")
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages.presence || [ e.message ] }, status: :unprocessable_entity
        rescue R2StorageService::UploadError, Prawn::Errors::CannotFit => e
          Rails.logger.warn("Invoice PDF generation failed: #{e.class}: #{e.message}")
          render json: { error: "Unable to issue and store the invoice artifact" }, status: :unprocessable_entity
        end

        def download_artifact
          send_primary_artifact(disposition: params[:disposition] == "inline" ? "inline" : "attachment")
        end

        def record_delivery
          raise ArgumentError, "Issue the invoice before recording delivery" if @invoice.draft?

          Invoice.transaction do
            @invoice.lock!
            artifact = @invoice.primary_artifact
            delivery = @invoice.deliveries.create!(
              organization: @invoice.organization,
              invoice_artifact: artifact,
              channel: params.require(:channel),
              recipient: params[:recipient].presence || @invoice.invoice_recipient.email,
              delivered_at: params[:delivered_at].presence || Time.current,
              provider_reference: params[:provider_reference],
              notes: params[:notes],
              recorded_by: current_user
            )
            @invoice.update!(sent_at: @invoice.sent_at || delivery.delivered_at, updated_by: current_user)
            InvoiceEvent.record!(
              invoice: @invoice,
              event_type: "delivery_recorded",
              actor: current_user,
              occurred_at: delivery.delivered_at,
              metadata: { delivery_id: delivery.id, channel: delivery.channel, recipient: delivery.recipient }
            )
          end

          render json: { invoice: InvoicePayloadBuilder.call(@invoice.reload, detailed: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def invoice_scope
          Invoice
            .where(organization_id: current_organization_id)
            .includes(
              :invoice_recipient, :invoice_billing_profile, :line_items, :created_by, :updated_by,
              :artifacts, :events, :deliveries,
              payments: [ :recorded_by, :reversed_by ],
              credit_notes: [ :issued_by, :voided_by ]
            )
        end

        def set_invoice
          @invoice = invoice_scope.find_by(id: params[:id])
          return if @invoice

          render json: { error: "Invoice not found" }, status: :not_found
        end

        def invoice_attributes
          raw = params.require(:invoice).permit(
            :invoice_recipient_id,
            :invoice_billing_profile_id,
            :invoice_number,
            :invoice_date,
            :due_date,
            :currency,
            :customer_reference,
            :service_period_start,
            :service_period_end,
            :notes,
            :payment_terms,
            :email_subject,
            :email_body
          )

          validate_recipient!(raw[:invoice_recipient_id]) if raw[:invoice_recipient_id].present?
          validate_billing_profile!(raw[:invoice_billing_profile_id]) if raw[:invoice_billing_profile_id].present?
          raw
        end

        def validate_recipient!(id)
          recipient = InvoiceRecipient.find_by(id: id, organization_id: current_organization_id)
          raise ArgumentError, "Invoice recipient not found" unless recipient
          raise ArgumentError, "Invoice recipient is archived" unless recipient.active? || @invoice&.invoice_recipient_id == recipient.id

          recipient
        end

        def validate_billing_profile!(id)
          profile = InvoiceBillingProfile.find_by(id: id, organization_id: current_organization_id)
          raise ArgumentError, "Invoice billing profile not found" unless profile
          raise ArgumentError, "Invoice billing profile is archived" unless profile.active? || @invoice&.invoice_billing_profile_id == profile.id

          profile
        end

        def optional_source_company
          company_id = params.dig(:invoice, :company_id).presence
          return nil unless company_id

          company = Company.find_by(id: company_id, organization_id: current_organization_id)
          raise ArgumentError, "Source company not found" unless company

          company
        end

        def line_item_params
          Array(params.dig(:invoice, :line_items)).map do |item|
            item_hash = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item
            ActionController::Parameters.new(item_hash).permit(
              :id, :description, :quantity, :rate, :service_date, :position, :_destroy
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
            next if item.new_record? || kept_ids.include?(item.id) || item.marked_for_destruction?

            item.mark_for_destruction
          end
        end

        def build_imported_invoice
          recipient = validate_recipient!(params.require(:invoice_recipient_id))
          profile = validate_billing_profile!(params.require(:invoice_billing_profile_id))
          total = BigDecimal(params.require(:total_amount).to_s)
          raise ArgumentError, "Invoice total must be greater than zero" unless total.positive?

          invoice = Invoice.new(
            organization_id: current_organization_id,
            company: imported_source_company,
            invoice_recipient: recipient,
            invoice_billing_profile: profile,
            invoice_number: params.require(:invoice_number),
            invoice_date: Date.iso8601(params.require(:invoice_date)),
            due_date: params[:due_date].presence && Date.iso8601(params[:due_date]),
            currency: params[:currency].presence || "USD",
            customer_reference: params[:customer_reference],
            payment_terms: params[:payment_terms],
            notes: params[:notes],
            origin: "imported",
            total_amount: total,
            created_by: current_user,
            updated_by: current_user,
            source_metadata: { original_filename: params[:file]&.original_filename }
          )
          invoice.line_items.build(description: params[:description].presence || "Imported invoice", quantity: 1, rate: total, position: 0)
          invoice
        end

        def imported_source_company
          company_id = params[:company_id].presence
          return nil unless company_id

          Company.find_by(id: company_id, organization_id: current_organization_id) ||
            raise(ArgumentError, "Source company not found")
        end

        def import_issued_at
          return Time.current if params[:issued_at].blank?

          Time.zone.parse(params[:issued_at]) || raise(ArgumentError, "Issued time is invalid")
        end

        def import_delivery_attributes
          return nil if params[:delivered_at].blank?

          channel = params[:delivery_channel].presence || "other"
          raise ArgumentError, "Delivery channel is invalid" unless channel.in?(InvoiceDelivery::CHANNELS)

          delivered_at = Time.zone.parse(params[:delivered_at]) || raise(ArgumentError, "Delivered time is invalid")
          {
            channel: channel,
            recipient: params[:delivery_recipient].presence,
            delivered_at: delivered_at
          }
        end

        def create_import_delivery!(invoice, artifact, attributes)
          return unless attributes

          delivery = invoice.deliveries.create!(
            organization: invoice.organization,
            invoice_artifact: artifact,
            channel: attributes[:channel],
            recipient: attributes[:recipient] || invoice.invoice_recipient.email,
            delivered_at: attributes[:delivered_at],
            notes: "Historical delivery recorded during import",
            recorded_by: current_user
          )
          invoice.update!(sent_at: delivery.delivered_at)
          InvoiceEvent.record!(
            invoice: invoice,
            event_type: "delivery_recorded",
            actor: current_user,
            occurred_at: delivery.delivered_at,
            metadata: { delivery_id: delivery.id, source: "invoice_import" }
          )
        end

        def send_primary_artifact(disposition:)
          artifact = @invoice.primary_artifact
          unless artifact
            render json: { error: "This legacy invoice does not have a preserved artifact" }, status: :not_found
            return
          end

          bytes = InvoiceArtifactStorageService.new.download(artifact)
          unless bytes
            render json: { error: "Invoice artifact is unavailable" }, status: :not_found
            return
          end

          send_data bytes,
            filename: artifact.filename,
            type: artifact.content_type,
            disposition: disposition
        rescue R2StorageService::DownloadError => e
          Rails.logger.warn("Invoice artifact download failed: #{e.class}: #{e.message}")
          render json: { error: "Invoice artifact is unavailable" }, status: :unprocessable_entity
        end
      end
    end
  end
end
