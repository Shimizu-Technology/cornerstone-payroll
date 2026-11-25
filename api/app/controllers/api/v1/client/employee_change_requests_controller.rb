# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeeChangeRequestsController < BaseController
        SENSITIVE_PAYLOAD_KEYS = %w[ssn ssn_encrypted contractor_ein sensitive_payload_encrypted].freeze

        before_action :set_change_request, only: [ :show, :approve, :reject ]

        rescue_from EmployeeChangeRequest::Cancelled do |error|
          render json: { error: error.message }, status: :conflict
        end

        rescue_from EmployeeProfileIdentity::LinkCheckUnavailable do |error|
          render json: { error: error.message }, status: :service_unavailable
        end

        def index
          requests = visible_requests
                                          .includes(:employee, :requested_by, :reviewed_by)
                                          .recent_first

          requests = requests.where(status: params[:status]) if params[:status].present?
          if (search = params[:search].to_s.strip.presence)
            query = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
            requests = requests.joins(:employee).where(
              "employees.first_name ILIKE :q OR employees.last_name ILIKE :q OR CONCAT_WS(' ', employees.first_name, employees.last_name) ILIKE :q",
              q: query
            )
          end

          requests = bounded_page(requests)

          render json: { data: requests.map { |request| serialize_change_request(request) }, meta: bounded_page_meta(requests).merge(profile_requests_enabled: profile_requests_enabled?) }
        end

        def show
          render json: { data: serialize_change_request(@change_request, include_payloads: true) }
        end

        def contact_changes
          return head :not_found unless profile_requests_enabled?

          changes = bounded_page(EmployeeContactChangeToConfirm.where(company_id: current_company_id)
            .includes(:employee, :changed_by).recent_first)
          render json: { data: changes.map(&:as_activity_json), meta: bounded_page_meta(changes) }
        end

        def approve
          decide(:apply!)
        end

        def reject
          decide(:reject!)
        end

        private

        def decide(action)
          return head :not_found unless profile_requests_enabled? && @change_request.profile_address?

          EmployeeChangeRequest.transaction do
            @change_request.public_send(action, actor: current_user, review_notes: params[:review_notes].to_s.presence)
            AuditLog.record!(
              user: current_user, company_id: current_company_id, action: "employee_change_requests##{action_name}",
              record_type: "employee_change_requests", record_id: @change_request.id,
              metadata: { employee_id: @change_request.employee_id }, ip_address: request.remote_ip, user_agent: request.user_agent
            )
          end
          render json: { data: serialize_change_request(@change_request, include_payloads: true) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end

        def profile_requests_enabled?
          return @profile_requests_enabled if defined?(@profile_requests_enabled)

          @profile_requests_enabled = CompanyFeatures.for(current_company).employee_portal_feature?(:profile_requests)
        end

        def visible_requests
          company_requests = EmployeeChangeRequest.for_company(current_company_id)
          own_requests = company_requests.where(requested_by_id: current_user.id)
          return own_requests unless profile_requests_enabled?

          own_requests.or(company_requests.where(id: company_requests.profile_addresses.select(:id)))
        end

        def set_change_request
          @change_request = visible_requests.find_by(id: params[:id])
          return if @change_request

          render json: { error: "Change request not found" }, status: :not_found
        end

        def serialize_change_request(change_request, include_payloads: false)
          payload = {
            id: change_request.id,
            status: change_request.status,
            request_kind: change_request.request_kind,
            profile_address: change_request.profile_address?,
            note_visible_to_employee: change_request.requested_by_link_id.present?,
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

          if include_payloads && change_request.profile_address?
            fields = change_request.proposed_changes.keys
            current_values = change_request.pending? ? change_request.employee.slice(*fields) : change_request.original_values
            payload[:original_values] = current_values.slice(*fields)
            payload[:proposed_changes] = change_request.proposed_changes.slice(*fields)
            payload[:can_review] = profile_requests_enabled? && change_request.pending? && !change_request.same_person_reviewer?(current_user)
          elsif include_payloads
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
