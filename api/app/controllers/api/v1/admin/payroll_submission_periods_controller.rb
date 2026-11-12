# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Anyone processing this client's payroll can acknowledge, review, post
      # a draft or mark paid. Each action records who did it.
      class PayrollSubmissionPeriodsController < BaseController
        include PayrollSubmissionPeriodActions
        rescue_from ActiveRecord::RecordNotFound do |error|
          render json: { error: error.message }, status: :not_found
        end

        def acknowledge
          skip_default_audit_log!
          payroll_actions.acknowledge!(saved_period!, submission_id: params[:submission_id])
          render_period
        end

        def start_review
          skip_default_audit_log!
          payroll_actions.start_review!(saved_period!, note: params[:note])
          render_period
        end

        def mark_paid
          skip_default_audit_log!
          payroll_actions.mark_paid!(saved_period!, note: params[:note])
          render_period
        end

        # Draft paycheck and direct-deposit PDFs; post: false keeps them staff-only.
        def drafts
          skip_default_audit_log!
          payroll_actions.create_draft!(@entry, params: params.permit(:paycheck_pdf, :direct_deposit_pdf, :note, :post, :idempotency_key))
          render_period(:created)
        end

        def post_draft
          skip_default_audit_log!
          payroll_actions.post_draft!(saved_period!, draft_id: params[:draft_id])
          render_period
        end

        # Sent by the page after it was shown in the foreground, with the
        # latest client update it displayed. Later updates stay unread.
        def seen
          skip_default_audit_log!
          unless params[:foreground] == true || params[:foreground] == "true"
            return render json: { error: "A foreground display is required" }, status: :unprocessable_entity
          end

          saved_period!.mark_seen_through!(current_user, event_id: params.require(:displayed_event_id))
          head :no_content
        rescue ArgumentError, ActionController::ParameterMissing
          render json: { error: "A displayed update is required" }, status: :unprocessable_entity
        end
      end
    end
  end
end
