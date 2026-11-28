# frozen_string_literal: true

module Api
  module V1
    module Client
      class VerificationItemsController < BaseController
        MAX_RESPONSE_NOTE_LENGTH = 1000

        before_action :reject_closed_practice_copy, only: [ :respond ]

        def index
          items = EmployeeVerificationItem
            .where(company_id: current_company_id)
            .includes(:employee, :source_actor, :returned_by, :verified_by)
            .order(created_at: :desc, id: :desc)

          if params[:status].present? && EmployeeVerificationItem::STATUSES.include?(params[:status].to_s)
            items = items.where(status: params[:status].to_s)
          end
          if params[:employee_id].present?
            employee_id = parse_positive_id(params[:employee_id])
            return render json: { error: "Invalid employee_id filter" }, status: :unprocessable_entity unless employee_id

            items = items.where(employee_id: employee_id)
          end
          if params[:event_kind].present? && EmployeeVerificationItem::EVENT_KINDS.include?(params[:event_kind].to_s)
            items = items.where(event_kind: params[:event_kind].to_s)
          end

          items = bounded_page(items)
          render json: {
            data: items.map { |item| serialize_item(item) },
            meta: bounded_page_meta(items)
          }
        end

        def respond
          note = (params[:note].presence || params[:response_note].presence).to_s.strip
          if note.blank?
            return render json: { error: "Provide a response note before resubmitting." }, status: :unprocessable_entity
          end
          if note.length > MAX_RESPONSE_NOTE_LENGTH
            return render json: { error: "Response note must be #{MAX_RESPONSE_NOTE_LENGTH} characters or fewer." }, status: :unprocessable_entity
          end

          expected_mode = nil
          unless CompanyFeatures::LOCKED_OFF.include?("client_portal.employee_lifecycle_mode")
            activation_result = ClientOperatingProfiles::LifecycleModeActivationService.ensure_attempted!(current_company)
            if activation_result&.activated?
              return render json: {
                error: "This company switched to Client-managed employee lifecycle. Reload and submit your change again.",
                code: "lifecycle_mode_changed",
                employee_lifecycle_mode: "client_managed"
              }, status: :conflict
            end
            expected_mode = CompanyFeatures.for(current_company).employee_lifecycle_mode
          end

          skip_default_audit_log!
          result = EmployeeVerificationItems::RespondService.call(
            company: current_company,
            actor: current_user,
            item_id: params[:id],
            note: note,
            expected_lifecycle_mode: expected_mode,
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            on_company_locked: -> { revalidate_client_company_write_access! }
          )

          unless result.success?
            payload = { error: result.error }
            payload[:code] = result.code if result.code.present?
            payload[:employee_lifecycle_mode] = result.employee_lifecycle_mode if result.employee_lifecycle_mode.present?
            return render json: payload, status: result.status
          end

          render json: { data: serialize_item(result.item) }
        end

        private

        def parse_positive_id(value)
          return nil unless value.is_a?(String) || value.is_a?(Integer)

          text = value.to_s.strip
          return nil unless text.match?(/\A[1-9]\d{0,18}\z/)

          parsed = text.to_i
          parsed <= (2**63 - 1) ? parsed : nil
        end

        def reject_closed_practice_copy
          return unless current_company&.test_workspace_read_only?

          render json: { error: "This practice copy is read-only. Your changes were not saved." }, status: :forbidden
        end

        def serialize_item(item)
          {
            id: item.id,
            employee_id: item.employee_id,
            employee_name: item.employee.full_name,
            event_kind: item.event_kind,
            status: item.status,
            affects_pay: item.affects_pay,
            effective_on: item.effective_on&.iso8601,
            changed_fields: item.changed_fields,
            before_values: EmployeeVerificationItems::Recorder.sanitize_values(item.before_values),
            after_values: EmployeeVerificationItems::Recorder.sanitize_values(item.after_values),
            return_note: item.return_note,
            returned_at: item.returned_at&.utc&.iso8601,
            resubmitted_at: item.resubmitted_at&.utc&.iso8601,
            verified_at: item.verified_at&.utc&.iso8601,
            fixed_by_staff: item.fixed_by_staff,
            client_response_note: item.metadata.to_h["client_response_note"],
            created_at: item.created_at&.utc&.iso8601,
            updated_at: item.updated_at&.utc&.iso8601(6)
          }
        end
      end
    end
  end
end
