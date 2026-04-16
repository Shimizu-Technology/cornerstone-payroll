# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PrinterProfilesController < BaseController
        before_action :set_profile, only: [:show, :update, :destroy, :apply]

        # GET /api/v1/admin/printer_profiles
        def index
          profiles = current_company.printer_profiles.ordered
          render json: { printer_profiles: profiles.map { |p| profile_json(p) } }
        end

        # GET /api/v1/admin/printer_profiles/:id
        def show
          render json: { printer_profile: profile_json(@profile) }
        end

        # POST /api/v1/admin/printer_profiles
        def create
          profile = current_company.printer_profiles.build(profile_params)
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
          @profile.destroy
          head :no_content
        end

        # POST /api/v1/admin/printer_profiles/:id/apply
        # Applies this profile's settings to the company's active check settings
        def apply
          if current_company.update(
            check_stock_type: @profile.check_stock_type,
            check_offset_x: @profile.check_offset_x,
            check_offset_y: @profile.check_offset_y,
            check_layout_config: @profile.check_layout_config
          )
            render json: {
              printer_profile: profile_json(@profile),
              check_settings: {
                check_stock_type: current_company.check_stock_type,
                check_offset_x: current_company.check_offset_x,
                check_offset_y: current_company.check_offset_y,
                check_layout_config: current_company.check_layout_config
              }
            }
          else
            render json: { errors: current_company.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def current_company
          @current_company ||= Company.find(current_company_id)
        end

        def set_profile
          @profile = current_company.printer_profiles.find(params[:id])
        end

        def profile_params
          params.require(:printer_profile).permit(
            :name, :description, :notes,
            :check_stock_type, :check_offset_x, :check_offset_y,
            :is_default,
            check_layout_config: {}
          )
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
            created_at: profile.created_at,
            updated_at: profile.updated_at
          }
        end
      end
    end
  end
end
