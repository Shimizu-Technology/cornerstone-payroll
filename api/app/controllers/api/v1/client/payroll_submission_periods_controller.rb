# frozen_string_literal: true

module Api
  module V1
    module Client
      class PayrollSubmissionPeriodsController < BaseController
        before_action :require_payroll_files
        include PayrollSubmissionPeriodActions

        # Send a new revision: Revel payroll PDF, changes, notes, attachments.
        def submissions
          skip_default_audit_log!
          result = PayrollSubmissions::CreateRevision.new(
            company: payroll_catalog_company, actor: current_user, entry: @entry, catalog: payroll_catalog,
            params: params.permit(:revel_payroll, :changes_workbook, :workbook_choice, :no_changes, :changes_link_url, :notes,
              :idempotency_key, :based_on_revision, attachments: [], keep_document_ids: []).to_h.merge(changes: params[:changes]),
            request_context: payroll_request_context
          ).call
          @entry = payroll_catalog.resolve(result.submission.payroll_submission_period_id)
          render json: { data: payroll_serializer.detail(@entry), outcome: result.outcome },
            status: result.outcome == :created ? :created : :ok
        end

        # Approve the posted draft, or request a change with a note.
        def decision
          skip_default_audit_log!
          payroll_actions.decide!(saved_period!, decision: params[:decision], draft_id: params[:draft_id], note: params[:note])
          render_period
        rescue ActiveRecord::RecordNotFound => error
          render json: { error: error.message }, status: :not_found
        end
        private

        def require_payroll_files
          unless payroll_catalog_company.payroll_intake_source_enabled?("mosa_revel")
            render json: { error: "Payroll files are not enabled for this client" }, status: :forbidden
          end
        end
      end
    end
  end
end
