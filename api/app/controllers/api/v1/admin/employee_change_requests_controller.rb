# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeChangeRequestsController < BaseController
        before_action :require_admin_or_manager!
        before_action :set_change_request, only: [ :show, :approve, :reject ]

        def index
          requests = EmployeeChangeRequest.for_company(current_company_id)
                                          .includes(:employee, :requested_by, :reviewed_by)
                                          .recent_first

          requests = requests.where(status: params[:status]) if params[:status].present?
          render json: { data: requests.map { |request| serialize_change_request(request) } }
        end

        def show
          render json: { data: serialize_change_request(@change_request, include_payloads: true) }
        end

        def approve
          @change_request.apply!(actor: current_user, review_notes: params[:review_notes])

          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: "employee_change_requests#approve",
            record_type: "employee_change_requests",
            record_id: @change_request.id,
            metadata: { employee_id: @change_request.employee_id },
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )

          render json: { data: serialize_change_request(@change_request.reload, include_payloads: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end

        def reject
          @change_request.reject!(actor: current_user, review_notes: params[:review_notes].to_s)

          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: "employee_change_requests#reject",
            record_type: "employee_change_requests",
            record_id: @change_request.id,
            metadata: { employee_id: @change_request.employee_id },
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )

          render json: { data: serialize_change_request(@change_request.reload, include_payloads: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end

        private

        def set_change_request
          @change_request = EmployeeChangeRequest.find_by(id: params[:id], company_id: current_company_id)
          return if @change_request

          render json: { error: "Change request not found" }, status: :not_found
        end

        def serialize_change_request(change_request, include_payloads: false)
          payload = {
            id: change_request.id,
            status: change_request.status,
            employee_id: change_request.employee_id,
            employee_name: change_request.employee.full_name,
            requested_by_id: change_request.requested_by_id,
            requested_by_name: change_request.requested_by&.name,
            reviewed_by_id: change_request.reviewed_by_id,
            reviewed_by_name: change_request.reviewed_by&.name,
            request_notes: change_request.request_notes,
            review_notes: change_request.review_notes,
            created_at: change_request.created_at,
            reviewed_at: change_request.reviewed_at
          }

          if include_payloads
            payload[:proposed_changes] = change_request.proposed_changes
            payload[:original_values] = change_request.original_values
            payload[:direct_changes_applied] = change_request.direct_changes_applied
          end

          payload
        end
      end
    end
  end
end
