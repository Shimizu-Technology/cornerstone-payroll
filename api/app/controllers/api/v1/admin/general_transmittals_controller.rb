# frozen_string_literal: true

module Api
  module V1
    module Admin
      class GeneralTransmittalsController < BaseController
        before_action :set_transmittal, only: [ :show, :update, :destroy, :preview_pdf, :generate_pdf ]

        def index
          transmittals = GeneralTransmittal
            .where(company_id: current_company_id)
            .includes(:items, :created_by, :updated_by)
            .recent

          render json: {
            general_transmittals: transmittals.map { |transmittal| transmittal_payload(transmittal) }
          }
        end

        def show
          render json: { general_transmittal: transmittal_payload(@transmittal, detailed: true) }
        end

        def create
          transmittal = GeneralTransmittal.new(transmittal_attributes)
          transmittal.company_id = current_company_id
          transmittal.created_by = current_user
          transmittal.updated_by = current_user
          apply_items!(transmittal)

          if transmittal.save
            render json: { general_transmittal: transmittal_payload(transmittal.reload, detailed: true) }, status: :created
          else
            render json: { errors: transmittal.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update
          @transmittal.assign_attributes(transmittal_attributes)
          @transmittal.updated_by = current_user
          @transmittal.status = "draft" if @transmittal.generated? && params[:mark_draft] == "true"
          @transmittal.generated_at = nil if @transmittal.status == "draft"
          apply_items!(@transmittal)

          if @transmittal.save
            render json: { general_transmittal: transmittal_payload(@transmittal.reload, detailed: true) }
          else
            render json: { errors: @transmittal.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def destroy
          @transmittal.destroy!
          render json: { message: "General transmittal deleted" }
        end

        def preview_pdf
          generator = GeneralTransmittalPdfGenerator.new(@transmittal)
          send_data generator.generate,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "inline"
        end

        def generate_pdf
          generator = GeneralTransmittalPdfGenerator.new(@transmittal)
          pdf_content = generator.generate

          @transmittal.mark_generated!(actor: current_user)
          send_data pdf_content,
            filename: generator.filename,
            type: "application/pdf",
            disposition: "attachment"
        end

        private

        def set_transmittal
          @transmittal = GeneralTransmittal
            .includes(:items, :created_by, :updated_by)
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
              :_destroy,
              details: []
            )
          end
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
            position: item_position(attrs, index)
          )
        end

        def item_position(attrs, index)
          attrs[:position].presence || index
        end

        def transmittal_payload(transmittal, detailed: false)
          payload = {
            id: transmittal.id,
            company_id: transmittal.company_id,
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
            item_count: transmittal.items.size,
            total_amount: transmittal.items.sum { |item| (item.amount || 0).to_d }.to_f,
            created_at: transmittal.created_at,
            updated_at: transmittal.updated_at
          }

          payload[:items] = transmittal.items.map { |item| item_payload(item) } if detailed
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
            created_at: item.created_at,
            updated_at: item.updated_at
          }
        end
      end
    end
  end
end
