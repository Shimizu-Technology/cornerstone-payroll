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
            applied_by: current_user,
            acknowledge_negative_adjustments: permitted[:acknowledge_negative_adjustments],
            negative_adjustment_note: permitted[:negative_adjustment_note]
          ).call

          status = results[:errors].any? ? :unprocessable_entity : :ok
          render json: { results: results, import: import_json(import.reload) }, status: status
        rescue ArgumentError, ActiveRecord::RecordInvalid, TimeTrackingEmployeeMapping::IdentityConflict => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Time tracking import not found" }, status: :not_found
        end

        def reconcile
          permitted = reconcile_params
          import = @pay_period.time_tracking_imports.find(permitted[:import_id])
          results = TimeTracking::ReconcileCommittedImportService.new(
            import: import,
            mappings: permitted[:mappings] || [],
            reconciled_by: current_user,
            reconciliation_note: permitted[:reconciliation_note]
          ).call

          render json: { data: { results: results, import: import_json(import.reload) } }
        rescue ArgumentError, ActiveRecord::RecordInvalid, TimeTrackingEmployeeMapping::IdentityConflict => e
          render json: { error: e.message, details: [] }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Time tracking import not found", details: [] }, status: :not_found
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.find(params[:pay_period_id] || params[:id])
          return if @pay_period.company_id == current_company_id

          render json: { error: "Pay period not found" }, status: :not_found
        end

        def apply_params
          params.permit(
            :import_id,
            :acknowledge_negative_adjustments,
            :negative_adjustment_note,
            mappings: [
              :source_user_id,
              :employee_id,
              :include,
              { wage_rate_mappings: [ :source_category_id, :source_category_key, :source_category_name, :source_effective_rate_cents, :employee_wage_rate_id ] }
            ]
          )
        end

        def reconcile_params
          params.permit(
            :import_id,
            :reconciliation_note,
            mappings: [ :source_user_id, :employee_id ]
          )
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
            external_batch_id: import.external_batch_id,
            external_batch_checksum: import.external_batch_checksum,
            contract_version: import.contract_version,
            source_cutoff_at: import.source_cutoff_at,
            applied_at: import.applied_at,
            reconciled_at: import.reconciled_at,
            reconciliation_note: import.reconciliation_note,
            source_processing_status: import.source_processing_status,
            source_processing_synced_at: import.source_processing_synced_at,
            source_processing_sync_error: import.source_processing_sync_error
          }
        end
      end
    end
  end
end
