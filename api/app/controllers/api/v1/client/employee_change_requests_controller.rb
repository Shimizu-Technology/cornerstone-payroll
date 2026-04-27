# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeeChangeRequestsController < BaseController
        SENSITIVE_PAYLOAD_KEYS = %w[ssn ssn_encrypted contractor_ein].freeze

        before_action :set_change_request, only: [ :show ]

        def index
          requests = EmployeeChangeRequest.for_company(current_company_id)
                                          .where(requested_by_id: current_user.id)
                                          .includes(:employee, :requested_by, :reviewed_by)
                                          .recent_first

          requests = requests.where(status: params[:status]) if params[:status].present?
          if params[:search].present?
            query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
            requests = requests.joins(:employee).where(
              "employees.first_name ILIKE :q OR employees.last_name ILIKE :q OR CONCAT_WS(' ', employees.first_name, employees.last_name) ILIKE :q",
              q: query
            )
          end

          render json: { data: requests.map { |request| serialize_change_request(request) } }
        end

        def show
          render json: { data: serialize_change_request(@change_request, include_payloads: true) }
        end

        private

        def set_change_request
          @change_request = EmployeeChangeRequest.find_by(
            id: params[:id],
            company_id: current_company_id,
            requested_by_id: current_user.id
          )
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
            payload[:proposed_changes] = sanitize_payload(change_request.proposed_changes)
            payload[:original_values] = sanitize_payload(change_request.original_values)
            payload[:direct_changes_applied] = sanitize_payload(change_request.direct_changes_applied)
          end

          payload
        end

        def sanitize_payload(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, nested_value), sanitized|
              sanitized[key] = if SENSITIVE_PAYLOAD_KEYS.include?(key.to_s)
                "[REDACTED]"
              else
                sanitize_payload(nested_value)
              end
            end
          when Array
            value.map { |nested_value| sanitize_payload(nested_value) }
          else
            value
          end
        end
      end
    end
  end
end
