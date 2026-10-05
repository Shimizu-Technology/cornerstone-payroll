# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeHoursEvidenceController < BaseController
        before_action :disable_http_caching

        def show
          employee = Employee.where(company_id: current_company_id).find(params[:employee_id])
          render json: EmployeeHoursEvidence.new(employee: employee, actor: current_user,
            params: params.permit(:source_id, :period_id, :start_date, :end_date, :per_page, :cursor, :detail_per_page, :detail_cursor).to_h).call
        rescue ArgumentError => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        private

        def disable_http_caching
          response.headers["Cache-Control"] = "no-store"
          response.headers["Pragma"] = "no-cache"
        end
      end
    end
  end
end
