# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Organization profiles are shared calibration definitions. Selecting a
      # profile is a separate, user-scoped operation and never mutates a client.
      class PrinterProfilesController < BaseController
        before_action :set_profile, only: [ :show, :update, :destroy, :apply, :apply_to_all_companies ]

        def index
          profiles = current_organization.printer_profiles.ordered.includes(
            :created_by,
            :updated_by,
            :user_printer_profile_selections
          )
          selected_ids = selected_profile_ids
          render json: {
            printer_profiles: profiles.map { |profile| profile_json(profile, selected_ids: selected_ids) },
            selections: selections_by_stock.values.map { |selection| selection_json(selection) },
            active_printer_profile_id: selected_ids[current_company.check_stock_type]
          }
        end

        def show
          render json: { printer_profile: profile_json(@profile, selected_ids: selected_profile_ids) }
        end

        def create
          profile = current_organization.printer_profiles.build(profile_params)
          profile.created_by = current_user
          profile.updated_by = current_user

          if profile.save
            render json: { printer_profile: profile_json(profile, selected_ids: selected_profile_ids) }, status: :created
          else
            render json: { errors: profile.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          @profile.updated_by = current_user
          if @profile.update(profile_params)
            render json: { printer_profile: profile_json(@profile, selected_ids: selected_profile_ids) }
          else
            render json: { errors: @profile.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ActiveRecord::StaleObjectError
          render json: {
            error: "This printer profile changed while you were editing it. Reload the latest calibration and try again."
          }, status: :conflict
        end

        def destroy
          PrinterProfile.transaction do
            @profile.user_printer_profile_selections.delete_all
            @profile.update!(archived_at: Time.current, is_default: false, updated_by: current_user)
          end
          head :no_content
        end

        # Backward-compatible endpoint for a frontend/backend rolling deploy.
        # It now selects the profile only for the current operator.
        def apply
          selection = select_profile!(@profile)
          render json: {
            printer_profile: profile_json(@profile, selected_ids: selected_profile_ids),
            selection: selection_json(selection),
            check_settings: check_settings_json
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # The old organization-wide mutation is deliberately unavailable.
        def apply_to_all_companies
          render json: {
            error: "Printer choice is personal. Each operator can select this shared profile for themselves."
          }, status: :unprocessable_entity
        end

        # Backward-compatible endpoint: clear only this operator's selection
        # for the active client's stock type.
        def clear_active
          current_user.user_printer_profile_selections.where(
            organization_id: current_organization.id,
            check_stock_type: current_company.check_stock_type
          ).delete_all
          @selections_by_stock = nil
          render json: { check_settings: check_settings_json }
        end

        private

        def current_organization
          @current_organization ||= current_company.organization
        end

        def set_profile
          @profile = current_organization.printer_profiles.active.find_by(id: params[:id])
          return if @profile

          render json: { error: "Printer profile not found" }, status: :not_found
        end

        def profile_params
          params.require(:printer_profile).permit(
            :name, :description, :notes,
            :check_stock_type, :check_offset_x, :check_offset_y,
            :is_default, :lock_version,
            check_layout_config: {}
          )
        end

        def selections_by_stock
          @selections_by_stock ||= current_user.user_printer_profile_selections
            .where(organization_id: current_organization.id)
            .includes(:printer_profile)
            .index_by(&:check_stock_type)
        end

        def selected_profile_ids
          selections_by_stock.transform_values(&:printer_profile_id)
        end

        def select_profile!(profile)
          current_user.user_printer_profile_selections
            .find_or_initialize_by(
              organization_id: current_organization.id,
              check_stock_type: profile.check_stock_type
            ).tap do |selection|
              selection.printer_profile = profile
              selection.save!
              @selections_by_stock = nil
            end
        end

        def check_settings_json
          render_settings = CheckRenderSettings.resolve(company: current_company, actor: current_user)
          render_company = render_settings.apply_to(current_company)
          {
            check_stock_type: render_company.check_stock_type,
            check_offset_x: render_company.check_offset_x,
            check_offset_y: render_company.check_offset_y,
            check_layout_config: render_company.check_layout_config,
            active_printer_profile_id: render_settings.printer_profile&.id,
            active_printer_profile_name: render_settings.printer_profile&.name,
            active_printer_profile_lock_version: render_settings.printer_profile&.lock_version
          }
        end

        def selection_json(selection)
          {
            id: selection.id,
            check_stock_type: selection.check_stock_type,
            printer_profile_id: selection.printer_profile_id,
            printer_profile_name: selection.printer_profile.name,
            updated_at: selection.updated_at
          }
        end

        def profile_json(profile, selected_ids:)
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
            created_by_id: profile.created_by_id,
            created_by_name: profile.created_by&.name,
            updated_by_id: profile.updated_by_id,
            updated_by_name: profile.updated_by&.name,
            selection_count: profile.user_printer_profile_selections.size,
            selected_for_current_user: selected_ids[profile.check_stock_type] == profile.id,
            lock_version: profile.lock_version,
            created_at: profile.created_at,
            updated_at: profile.updated_at
          }
        end
      end
    end
  end
end
