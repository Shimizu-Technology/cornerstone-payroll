# frozen_string_literal: true

module Api
  module V1
    module Admin
      class AireHistoryApprovalsController < BaseController
        include ConnectedPayrollControl
        before_action :set_source
        before_action :require_history_access!
        before_action :require_connected_payroll!, except: :operation
        before_action { response.headers["Cache-Control"] = "no-store" }

        rescue_from TimeTracking::HistoryApproval::Error, TimeTracking::VerifiedHistoryRollout::Error,
          TimeTracking::Client::Error, TimeTrackingEmployeeMapping::IdentityConflict do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end
        rescue_from TimeTracking::HistoryApproval::Changed do |error|
          render json: { error: error.message, changes: error.changes }, status: :conflict
        end

        def preview
          arguments = { mapping_selections: object_list!(:mapping_selections, :source_user_uuid, :employee_id) }
          return enqueue("preview", arguments) if params[:background] == true
          render json: service.prepare!(**arguments)
        end

        def approve
          review = AireHistoryReview.find_by!(id: params[:review_id], company_id: current_company_id,
            time_tracking_source: @source, actor: current_user)
          permitted = params.permit(:digest, :attestation, confirmed_mapping_uuids: [], solo_choices: [ :employee_id, :employee_wage_rate_id ])
          arguments = { review_id: review.id, digest: permitted[:digest], attestation: permitted[:attestation],
            confirmed_mapping_uuids: Array(permitted[:confirmed_mapping_uuids]), solo_choices: object_list!(:solo_choices, :employee_id, :employee_wage_rate_id) }
          return enqueue("approve", arguments) if params[:background] == true
          render json: service.approve!(review: review, **arguments.except(:review_id))
        end

        def operation
          record = AireHistoryOperation.find_by!(id: params[:operation_id], company: @source.company,
            time_tracking_source: @source, actor: current_user)
          render json: record.response_payload
        end

        private

        def enqueue(kind, arguments)
          # Retrying a lost approval response reuses its operation, including
          # its exact Solo/mapping choices. A fresh preview always captures anew.
          key = kind == "preview" ? SecureRandom.uuid : TimeTracking::CanonicalPayload.checksum(arguments)
          operation = AireHistoryOperation.create_or_find_by!(actor: current_user, time_tracking_source: @source, request_key: key) do |record|
            record.company = @source.company
            record.kind = kind
            record.arguments = arguments
          end
          if operation.previously_new_record?
            job = AireHistoryOperationJob.perform_later(operation.id)
            unless job&.successfully_enqueued?
              operation.with_lock do
                operation.update!(status: "failed", finished_at: Time.current,
                  error: "History processing could not be queued. Nothing was applied. Refresh the summary before retrying.") if operation.status == "queued"
              end
            end
          end
          render json: operation.response_payload, status: :accepted
        end

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
