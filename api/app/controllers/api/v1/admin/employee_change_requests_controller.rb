# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeChangeRequestsController < BaseController
        SENSITIVE_PAYLOAD_KEYS = %w[ssn ssn_encrypted contractor_ein sensitive_payload_encrypted].freeze

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
            request_kind: change_request.request_kind,
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
                masked_sensitive_value(key, nested_value)
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

        def masked_sensitive_value(key, value)
          return value if value.to_s.start_with?("***-**-", "Ending in ")

          digits = value.to_s.gsub(/\D/, "")
          return "[REDACTED]" if digits.blank?
          return "***-**-#{digits.last(4)}" if %w[ssn ssn_encrypted].include?(key.to_s)

          "Ending in #{digits.last(4)}"
        end
      end
    end
  end
end
