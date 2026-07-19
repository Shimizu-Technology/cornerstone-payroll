# frozen_string_literal: true

module Api
  module V1
    module Admin
      class GeneralTransmittalsController < BaseController
        before_action :set_transmittal, only: [ :show, :update, :destroy, :preview_pdf, :generate_pdf, :refresh_from_pay_period, :artifact_pdf ]

        def index
          transmittals = GeneralTransmittal
            .where(company_id: current_company_id)
            .includes(:items, :artifacts, :pay_period, :created_by, :updated_by)
            .recent

          render json: {
            general_transmittals: transmittals.map { |transmittal| transmittal_payload(transmittal) }
          }
        end

        def show
          render json: { general_transmittal: transmittal_payload(@transmittal, detailed: true) }
        end

        def from_pay_period
          pay_period = PayPeriod.find_by(id: params[:pay_period_id], company_id: current_company_id)
          unless pay_period
            render json: { error: "Pay period not found" }, status: :not_found
            return
          end

          transmittal = UnifiedTransmittalBootstrapService.new(pay_period: pay_period, actor: current_user).call
          render json: { general_transmittal: transmittal_payload(load_detailed(transmittal.id), detailed: true) }
        rescue ArgumentError => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def refresh_from_pay_period
          unless @transmittal.pay_period_source?
            render json: { error: "Only pay-period transmittals can be refreshed" }, status: :unprocessable_entity
            return
          end
          unless @transmittal.pay_period
            render json: { error: "The source pay period is no longer available" }, status: :unprocessable_entity
            return
          end

          transmittal = UnifiedTransmittalBootstrapService.new(pay_period: @transmittal.pay_period, actor: current_user).call
          render json: { general_transmittal: transmittal_payload(load_detailed(transmittal.id), detailed: true) }
        end

        def create
          transmittal = GeneralTransmittal.new(transmittal_attributes)
          transmittal.company_id = current_company_id
          transmittal.created_by = current_user
          transmittal.updated_by = current_user
          saved = GeneralTransmittal.transaction do
            apply_items!(transmittal)
            transmittal.save
          end

          if saved
            render json: { general_transmittal: transmittal_payload(transmittal.reload, detailed: true) }, status: :created
          else
            render json: { errors: transmittal.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: [ "Source item has already been added to this transmittal" ] }, status: :unprocessable_entity
        end

        def update
          if generated_update_without_draft_mark?
            render json: {
              error: "Cannot modify a generated transmittal without marking it as draft"
            }, status: :unprocessable_entity
            return
          end

          saved = GeneralTransmittal.transaction do
            @transmittal.lock!
            @transmittal.assign_attributes(transmittal_attributes)
            @transmittal.updated_by = current_user
            @transmittal.status = "draft" if @transmittal.generated? && params[:mark_draft] == "true"
            @transmittal.generated_at = nil if @transmittal.status == "draft"
            apply_items!(@transmittal)
            @transmittal.save
          end

          if saved
            render json: { general_transmittal: transmittal_payload(@transmittal.reload, detailed: true) }
          else
            render json: { errors: @transmittal.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { errors: [ "Source item has already been added to this transmittal" ] }, status: :unprocessable_entity
        end

        def destroy
          if @transmittal.generated?
            render json: { error: "Generated transmittals cannot be deleted" }, status: :unprocessable_entity
            return
          end
          if @transmittal.artifacts.exists?
            render json: { error: "Transmittals with generated versions cannot be deleted" }, status: :unprocessable_entity
            return
          end

          @transmittal.destroy!
          render json: { message: "General transmittal deleted" }
        end

        def preview_pdf
          generator = GeneralTransmittalPdfGenerator.new(@transmittal)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "inline"
        rescue Prawn::Errors::CannotFit => e
          render_pdf_generation_error(e)
        end

        def generate_pdf
          return unless ensure_items_for_generation!

          result = GeneralTransmittalArtifactService.new(transmittal: @transmittal, actor: current_user).generate!
          send_data result.pdf_bytes,
            filename: result.artifact.filename,
            type: "application/pdf",
            disposition: "attachment"
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages.presence || [ e.message ] }, status: :unprocessable_entity
        rescue Prawn::Errors::CannotFit => e
          render_pdf_generation_error(e)
        rescue R2StorageService::UploadError => error
          Rails.logger.error("Transmittal artifact upload failed: #{error.class}: #{error.message}")
          render json: { error: "Unable to preserve the generated transmittal" }, status: :service_unavailable
        rescue ActiveRecord::RecordNotUnique
          render json: {
            error: "Another transmittal version was generated at the same time. Refresh and try again."
          }, status: :conflict
        end

        def artifact_pdf
          artifact = @transmittal.artifacts.find(params[:artifact_id])
          bytes = GeneralTransmittalArtifactService.new(transmittal: @transmittal, actor: current_user).download!(artifact)
          send_data bytes,
            filename: artifact.filename,
            type: artifact.content_type,
            disposition: params[:download] == "true" ? "attachment" : "inline"
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Generated transmittal version not found" }, status: :not_found
        rescue R2StorageService::DownloadError => error
          Rails.logger.error("Transmittal artifact download failed: #{error.class}: #{error.message}")
          render json: { error: "Unable to load the generated transmittal version" }, status: :service_unavailable
        end

        private

        def set_transmittal
          @transmittal = GeneralTransmittal
            .includes(:items, :artifacts, :pay_period, :created_by, :updated_by)
            .find_by(id: params[:id], company_id: current_company_id)
          return if @transmittal

          render json: { error: "General transmittal not found" }, status: :not_found
        end

        def transmittal_attributes
          raw = params.require(:general_transmittal).permit(
            :title,
            :transmittal_date,
            :preparer_name,
            :recipient_name,
            notes: []
          )
          raw[:notes] = Array(raw[:notes]).map(&:to_s) if raw.key?(:notes)
          raw
        end

        def item_params
          Array(params.dig(:general_transmittal, :items)).map do |item|
            item_hash = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item
            ActionController::Parameters.new(item_hash).permit(
              :id,
              :source_type,
              :source_id,
              :item_type,
              :title,
              :payable_to,
              :check_number,
              :amount,
              :position,
              :included,
              :_destroy,
              details: []
            )
          end
        end

        def generated_update_without_draft_mark?
          @transmittal.generated? &&
            params[:mark_draft] != "true"
        end

        def ensure_items_for_generation!
          return true if @transmittal.included_items.any?

          render json: { errors: [ "Items must include at least one item" ] }, status: :unprocessable_entity
          false
        end

        def render_pdf_generation_error(error)
          Rails.logger.warn(
            "General transmittal PDF generation failed: #{error.class}: #{error.message}"
          )
          render json: { error: "Unable to generate transmittal PDF" }, status: :unprocessable_entity
        end

        def apply_items!(transmittal)
          return unless params.dig(:general_transmittal, :items)

          existing_by_id = transmittal.items.index_by { |item| item.id&.to_s }
          kept_ids = []
          built_items = []

          item_params.each_with_index do |attrs, index|
            if ActiveModel::Type::Boolean.new.cast(attrs[:_destroy])
              existing_by_id[attrs[:id].to_s]&.mark_for_destruction if attrs[:id].present?
              next
            end

            item = attrs[:id].present? ? existing_by_id[attrs[:id].to_s] : nil
            item ||= transmittal.items.build
            hydrate_item!(item, attrs, index)
            kept_ids << item.id if item.persisted?
            built_items << item
          end

          transmittal.items.each do |item|
            next if item.new_record?
            next if kept_ids.include?(item.id)
            next if item.marked_for_destruction?

            item.mark_for_destruction
          end

          built_items
        end

        def hydrate_item!(item, attrs, index)
          if item.persisted? && item.source_key.present?
            assign_item_attributes!(
              item,
              attrs,
              index,
              source_type: item.source_type,
              source_id: item.source_id,
              item_type: item.item_type
            )
            return
          end

          if attrs[:source_type] == "NonEmployeeCheck" && attrs[:source_id].present?
            check = standalone_check!(attrs[:source_id])
            if resnapshot_item?(item, check)
              assign_check_snapshot!(item, check, attrs, index)
            else
              assign_item_attributes!(
                item,
                attrs,
                index,
                source_type: "NonEmployeeCheck",
                source_id: check.id,
                item_type: "check"
              )
            end
            return
          end

          assign_item_attributes!(item, attrs, index)
        end

        def standalone_check!(source_id)
          check = NonEmployeeCheck.find_by(id: source_id, company_id: current_company_id)
          raise ArgumentError, "Standalone check not found" unless check
          if check.pay_period_id.present?
            raise ArgumentError, "Only standalone checks can be added to general transmittals"
          end
          raise ArgumentError, "Voided checks cannot be added to general transmittals" if check.voided?

          check
        end

        def resnapshot_item?(item, check)
          !item.persisted? || item.source_type != "NonEmployeeCheck" || item.source_id.to_i != check.id
        end

        def assign_check_snapshot!(item, check, attrs, index)
          snapshot = GeneralTransmittalItem.from_non_employee_check(check, position: item_position(attrs, index))
          item.assign_attributes(
            snapshot.attributes.except("id", "created_at", "updated_at", "general_transmittal_id")
          )
        end

        def assign_item_attributes!(item, attrs, index, source_type: nil, source_id: nil, item_type: nil)
          item.assign_attributes(
            source_type: source_type || attrs[:source_type].presence,
            source_id: source_id || attrs[:source_id].presence,
            item_type: item_type || attrs[:item_type].presence || "manual",
            title: attrs[:title],
            payable_to: attrs[:payable_to].presence,
            check_number: attrs[:check_number].presence,
            amount: attrs[:amount].presence,
            details: Array(attrs[:details]).map(&:to_s),
            position: item_position(attrs, index),
            included: attrs.key?(:included) ? ActiveModel::Type::Boolean.new.cast(attrs[:included]) : item.included
          )
        end

        def item_position(attrs, index)
          attrs[:position].presence || index
        end

        def transmittal_payload(transmittal, detailed: false)
          payload = {
            id: transmittal.id,
            company_id: transmittal.company_id,
            pay_period_id: transmittal.pay_period_id,
            source_kind: transmittal.source_kind,
            title: transmittal.title,
            transmittal_date: transmittal.transmittal_date,
            preparer_name: transmittal.preparer_name,
            recipient_name: transmittal.recipient_name,
            notes: transmittal.notes || [],
            status: transmittal.status,
            generated_at: transmittal.generated_at,
            created_by_id: transmittal.created_by_id,
            created_by_name: transmittal.created_by&.name,
            updated_by_id: transmittal.updated_by_id,
            updated_by_name: transmittal.updated_by&.name,
            item_count: transmittal.included_items.size,
            total_amount: transmittal.included_items.sum { |item| (item.amount || 0).to_d }.to_f,
            artifact_count: transmittal.artifacts.size,
            created_at: transmittal.created_at,
            updated_at: transmittal.updated_at
          }

          if transmittal.pay_period
            payload[:pay_period] = {
              id: transmittal.pay_period.id,
              start_date: transmittal.pay_period.start_date,
              end_date: transmittal.pay_period.end_date,
              pay_date: transmittal.pay_period.pay_date,
              status: transmittal.pay_period.status
            }
          end
          if detailed
            payload[:items] = transmittal.items.map { |item| item_payload(item) }
            payload[:artifacts] = transmittal.artifacts.map { |artifact| artifact_payload(artifact) }
          end
          payload
        end

        def item_payload(item)
          {
            id: item.id,
            source_type: item.source_type,
            source_id: item.source_id,
            item_type: item.item_type,
            title: item.title,
            payable_to: item.payable_to,
            check_number: item.check_number,
            amount: item.amount&.to_f,
            details: item.details || [],
            position: item.position,
            included: item.included,
            source_key: item.source_key,
            metadata: item.metadata || {},
            created_at: item.created_at,
            updated_at: item.updated_at
          }
        end

        def artifact_payload(artifact)
          {
            id: artifact.id,
            version_number: artifact.version_number,
            filename: artifact.filename,
            content_type: artifact.content_type,
            byte_size: artifact.byte_size,
            sha256: artifact.sha256,
            template_version: artifact.template_version,
            created_by_id: artifact.created_by_id,
            created_by_name: artifact.created_by&.name,
            created_at: artifact.created_at
          }
        end

        def load_detailed(id)
          GeneralTransmittal.includes(:items, :artifacts, :pay_period, :created_by, :updated_by).find(id)
        end
      end
    end
  end
end
