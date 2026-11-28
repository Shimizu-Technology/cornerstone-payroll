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

          item = nil
          error_response = nil
          skip_default_audit_log!
          ActiveRecord::Base.transaction do
            Company.lock.find(current_company_id)
            revalidate_client_company_write_access!
            current_mode = CompanyFeatures.for(current_company).employee_lifecycle_mode
            if expected_mode.present? && current_mode != expected_mode
              error_response = [ {
                error: "This company's employee lifecycle mode changed. Reload and submit your change again.",
                code: "lifecycle_mode_changed",
                employee_lifecycle_mode: current_mode
              }, :conflict ]
              next
            end
            unless current_mode == "client_managed"
              error_response = [ {
                error: "Client-managed employee lifecycle is not enabled for this company.",
                code: "client_lifecycle_disabled"
              }, :forbidden ]
              next
            end

            item = EmployeeVerificationItem.where(company_id: current_company_id).lock.find_by(id: params[:id])
            unless item
              error_response = [ { error: "Verification item not found" }, :not_found ]
              next
            end

            unless item.status == "returned_to_client"
              error_response = [ { error: "Only sent-back verification items can be responded to." }, :unprocessable_entity ]
              next
            end

            now = Time.current
            response_metadata = {
              "client_response_note" => note,
              "client_responded_by_id" => current_user.id,
              "client_responded_at" => now.utc.iso8601
            }
            if item.acknowledged_in_committed_run?
              existing_linked = EmployeeVerificationItem
                .where(company_id: item.company_id, employee_id: item.employee_id)
                .open_items
                .where("metadata ->> 'prior_unverified_item_id' = ?", item.id.to_s)
                .order(created_at: :desc, id: :desc)
                .lock
                .to_a
                .find { |candidate| !candidate.acknowledged_in_committed_run? }

              if existing_linked
                existing_note = existing_linked.metadata.to_h["client_response_note"].to_s.strip.presence
                appended_note = existing_note.present? ? "#{existing_note}\n\n#{note}" : note
                existing_linked.update!(
                  status: "pending_verification",
                  resubmitted_at: now,
                  source_actor: current_user,
                  metadata: existing_linked.metadata.to_h.merge(response_metadata, "client_response_note" => appended_note)
                )
                item = existing_linked
              else
                item = EmployeeVerificationItem.create!(
                  company_id: item.company_id,
                  employee: item.employee,
                  event_kind: item.event_kind,
                  status: "pending_verification",
                  affects_pay: item.affects_pay,
                  effective_on: item.effective_on,
                  source_actor: current_user,
                  source_record: item.source_record,
                  changed_fields: item.changed_fields,
                  before_values: item.before_values,
                  after_values: item.after_values,
                  resubmitted_at: now,
                  metadata: item.metadata.to_h.merge(response_metadata).merge("prior_unverified_item_id" => item.id)
                )
              end
            else
              item.update!(
                status: "pending_verification",
                resubmitted_at: now,
                source_actor: current_user,
                metadata: item.metadata.to_h.merge(response_metadata)
              )
            end

            AuditLog.record!(
              user: current_user,
              company_id: current_company_id,
              action: "employee_verification_items#respond",
              record_type: "employee_verification_items",
              record_id: item.id,
              subject_name: item.employee.full_name,
              metadata: {
                employee_id: item.employee_id,
                event_kind: item.event_kind,
                response_note: note
              },
              ip_address: request.remote_ip,
              user_agent: request.user_agent
            )
            PortalNotifications.employee_verification_queued!(item)
          end

          return render json: error_response[0], status: error_response[1] if error_response

          render json: { data: serialize_item(item.reload) }
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
