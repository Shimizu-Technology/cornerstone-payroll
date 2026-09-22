# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PrinterProfileSelectionsController < BaseController
        def update
          stock_type = params[:check_stock_type].to_s
          unless Company::CHECK_STOCK_TYPES.include?(stock_type)
            return render json: { error: "Unsupported check stock type" }, status: :unprocessable_entity
          end

          selection = PrinterProfile.transaction do
            profile = current_company.organization.printer_profiles.active.lock.find(params[:printer_profile_id])
            if profile.check_stock_type != stock_type
              raise CheckRenderSettings::IncompatibleProfileError,
                "#{profile.name} is calibrated for #{profile.check_stock_type.humanize}, not #{stock_type.humanize}"
            end

            current_user.user_printer_profile_selections.find_or_initialize_by(
              organization_id: current_company.organization_id,
              check_stock_type: stock_type
            ).tap do |record|
              record.printer_profile = profile
              record.save!
            end
          end

          render json: { selection: selection_json(selection) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Printer profile not found" }, status: :not_found
        rescue CheckRenderSettings::IncompatibleProfileError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        def destroy
          current_user.user_printer_profile_selections.where(
            organization_id: current_company.organization_id,
            check_stock_type: params[:check_stock_type]
          ).delete_all
          head :no_content
        end

        private

        def selection_json(selection)
          {
            id: selection.id,
            check_stock_type: selection.check_stock_type,
            printer_profile_id: selection.printer_profile_id,
            printer_profile_name: selection.printer_profile.name,
            updated_at: selection.updated_at
          }
        end
      end
    end
  end
end
