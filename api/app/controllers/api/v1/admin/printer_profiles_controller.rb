# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Printer profiles are scoped to the current organization so everyone in
      # the same accounting firm can reuse the same office printer calibration.
      # The `apply` action still writes to the currently active company's check
      # settings — that's the act of saying "use this printer here right now".
      class PrinterProfilesController < BaseController
        before_action :set_profile, only: [:show, :update, :destroy, :apply, :apply_to_all_companies]

        # GET /api/v1/admin/printer_profiles
        def index
          profiles = current_organization.printer_profiles.ordered
          render json: {
            printer_profiles: profiles.map { |p| profile_json(p) },
            active_printer_profile_id: current_company.active_printer_profile_id
          }
        end

        # GET /api/v1/admin/printer_profiles/:id
        def show
          render json: { printer_profile: profile_json(@profile) }
        end

        # POST /api/v1/admin/printer_profiles
        def create
          profile = current_organization.printer_profiles.build(profile_params)
          if profile.save
            render json: { printer_profile: profile_json(profile) }, status: :created
          else
            render json: { errors: profile.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/admin/printer_profiles/:id
        def update
          if @profile.update(profile_params)
            render json: { printer_profile: profile_json(@profile) }
          else
            render json: { errors: @profile.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/v1/admin/printer_profiles/:id
        def destroy
          Company.where(active_printer_profile_id: @profile.id).update_all(active_printer_profile_id: nil, updated_at: Time.current)
          @profile.destroy
          head :no_content
        end

        # POST /api/v1/admin/printer_profiles/:id/apply
        # Writes this profile's calibration into the currently-active
        # company's check settings.
        def apply
          if current_company.update(profile_check_settings(@profile))
            render json: {
              printer_profile: profile_json(@profile),
              check_settings: check_settings_json(current_company)
            }
          else
            render json: { errors: current_company.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # POST /api/v1/admin/printer_profiles/:id/apply_to_all_companies
        # Applies this shared office-printer calibration to every client in the
        # current organization so operators do not have to reselect the same
        # physical printer for each client separately.
        def apply_to_all_companies
          applied_count = 0
          Company.transaction do
            Company.where(organization_id: current_organization.id).find_each do |company|
              company.update!(profile_check_settings(@profile))
              applied_count += 1
            end
          end

          current_company.reload
          render json: {
            printer_profile: profile_json(@profile),
            applied_count: applied_count,
            check_settings: check_settings_json(current_company)
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/printer_profiles/clear_active
        # Keeps the current check settings, but disconnects them from any saved
        # printer preset so operators can clearly work without a selected preset.
        def clear_active
          if current_company.update(active_printer_profile: nil)
            render json: {
              check_settings: check_settings_json(current_company)
            }
          else
            render json: { errors: current_company.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def current_company
          @current_company ||= Company.find(current_company_id)
        end

        def current_organization
          @current_organization ||= current_company.organization
        end

        def set_profile
          @profile = current_organization.printer_profiles.find_by(id: params[:id])
          return if @profile

          render json: { error: "Printer profile not found" }, status: :not_found
        end

        def profile_params
          params.require(:printer_profile).permit(
            :name, :description, :notes,
            :check_stock_type, :check_offset_x, :check_offset_y,
            :is_default,
            check_layout_config: {}
          )
        end

        def profile_check_settings(profile)
          {
            check_stock_type: profile.check_stock_type,
            check_offset_x: profile.check_offset_x,
            check_offset_y: profile.check_offset_y,
            check_layout_config: profile.check_layout_config,
            active_printer_profile: profile
          }
        end

        def check_settings_json(company)
          {
            check_stock_type: company.check_stock_type,
            check_offset_x: company.check_offset_x,
            check_offset_y: company.check_offset_y,
            check_layout_config: company.check_layout_config,
            active_printer_profile_id: company.active_printer_profile_id,
            active_printer_profile_name: company.active_printer_profile&.name
          }
        end

        def profile_json(profile)
          {
            id: profile.id,
            name: profile.name,
            description: profile.description,
            notes: profile.notes,
            check_stock_type: profile.check_stock_type,
            check_offset_x: profile.check_offset_x,
            check_offset_y: profile.check_offset_y,
            check_layout_config: profile.check_layout_config,
            is_default: profile.is_default,
            organization_id: profile.organization_id,
            created_at: profile.created_at,
            updated_at: profile.updated_at
          }
        end
      end
    end
  end
end
