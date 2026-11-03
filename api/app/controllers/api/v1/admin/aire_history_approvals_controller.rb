# frozen_string_literal: true

module Api
  module V1
    module Admin
      class AireHistoryApprovalsController < BaseController
        include ConnectedPayrollControl
        before_action :set_source
        before_action :require_history_access!
        before_action :require_connected_payroll!
        before_action { response.headers["Cache-Control"] = "no-store" }

        rescue_from TimeTracking::HistoryApproval::Error, TimeTracking::VerifiedHistoryRollout::Error,
          TimeTracking::Client::Error, TimeTrackingEmployeeMapping::IdentityConflict do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end
        rescue_from TimeTracking::HistoryApproval::Changed do |error|
          render json: { error: error.message, changes: error.changes }, status: :conflict
        end

        def preview
          render json: service.prepare!(mapping_selections: object_list!(:mapping_selections, :source_user_uuid, :employee_id))
        end

        def approve
          review = AireHistoryReview.find_by!(id: params[:review_id], company_id: current_company_id,
            time_tracking_source: @source, actor: current_user)
          permitted = params.permit(:digest, :attestation, confirmed_mapping_uuids: [], solo_choices: [ :employee_id, :employee_wage_rate_id ])
          render json: service.approve!(review: review, digest: permitted[:digest], attestation: permitted[:attestation],
            confirmed_mapping_uuids: Array(permitted[:confirmed_mapping_uuids]), solo_choices: object_list!(:solo_choices, :employee_id, :employee_wage_rate_id))
        end

        private

        def object_list!(key, *fields)
          rows = params.fetch(key, [])
          unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(ActionController::Parameters) }
            raise TimeTracking::HistoryApproval::Error, "#{key} must be a list of objects"
          end
          rows.map { |row| row.permit(*fields).to_h }
        end

        def service
          TimeTracking::HistoryApproval.new(source: @source, actor: current_user)
        end

        def set_source
          @source = TimeTrackingSource.find_by!(id: params[:time_tracking_source_id], company_id: current_company_id)
        end

        def require_history_access!
          unless TimeTracking::HistoryApproval.allowed?(current_user, @source.company)
            render json: { error: "Organization admin or assigned payroll accountant access required" }, status: :forbidden
          end
        end
      end
    end
  end
end
