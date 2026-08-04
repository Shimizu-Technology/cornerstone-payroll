# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeWorkProfilesController < BaseController
        before_action :set_employee
        before_action :require_manager_or_admin!, only: :create

        def index
          profiles = @employee.employee_work_profiles.order(effective_on: :desc)
          render json: { data: profiles.map { |profile| serialize(profile) } }
        end

        def create
          profile = EmployeeWorkProfileChangeService.call!(
            employee: @employee,
            actor: current_user,
            attributes: work_profile_params
          )
          render json: { data: serialize(profile) }, status: :created
        rescue EmployeeWorkProfileChangeService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          render json: { error: "Employee not found" }, status: :not_found unless @employee
        end

        def work_profile_params
          params.require(:work_profile).permit(
            :effective_on,
            :pay_basis,
            :overtime_status,
            :exemption_category,
            :exemption_reason,
            :standard_weekly_hours,
            :timekeeping_mode,
            :source,
            :notes,
            daily_schedule: EmployeeWorkProfile::WEEKDAY_KEYS
          )
        end

        def serialize(profile)
          payload = profile.as_json(except: :notes)
          payload["notes"] = profile.notes if current_user&.manager? || current_user&.organization_admin?
          payload.merge("confirmed_by_name" => profile.confirmed_by&.name)
        end
      end
    end
  end
end
