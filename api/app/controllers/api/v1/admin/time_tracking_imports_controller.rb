# frozen_string_literal: true

module Api
  module V1
    module Admin
      class TimeTrackingImportsController < BaseController
        before_action :set_pay_period

        def preview
          source = TimeTrackingSource.find_by!(id: params[:source_id], company_id: current_company_id)
          import = TimeTracking::ImportPreviewService.new(
            pay_period: @pay_period,
            source: source,
            start_date: params[:start_date],
            end_date: params[:end_date]
          ).call

          render json: { import: import_json(import) }
        rescue TimeTracking::Client::Error, ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def apply
          permitted = apply_params
          import = @pay_period.time_tracking_imports.find(permitted[:import_id])
          results = TimeTracking::ApplyImportService.new(
            import: import,
            mappings: permitted[:mappings] || [],
            applied_by: current_user
          ).call

          status = results[:errors].any? ? :unprocessable_entity : :ok
          render json: { results: results, import: import_json(import.reload) }, status: status
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Time tracking import not found" }, status: :not_found
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.find(params[:pay_period_id] || params[:id])
          return if @pay_period.company_id == current_company_id

          render json: { error: "Pay period not found" }, status: :not_found
        end

        def apply_params
          params.permit(:import_id, mappings: [ :source_user_id, :employee_id, :include ])
        end

        def import_json(import)
          {
            id: import.id,
            status: import.status,
            time_tracking_source_id: import.time_tracking_source_id,
            source_name: import.time_tracking_source.name,
            start_date: import.start_date,
            end_date: import.end_date,
            fetch_start_date: import.fetch_start_date,
            fetch_end_date: import.fetch_end_date,
            warnings: import.warnings,
            processed_payload: import.processed_payload,
            applied_at: import.applied_at
          }
        end
      end
    end
  end
end
