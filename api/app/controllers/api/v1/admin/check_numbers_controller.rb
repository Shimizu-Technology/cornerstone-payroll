# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CheckNumbersController < BaseController
        def update
          pay_period = PayPeriod.where(company_id: current_company_id).find(params[:pay_period_id])
          result = CheckNumberBatchCorrectionService.new(
            pay_period: pay_period,
            changes: params[:changes],
            actor: current_user,
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            request_id: request.request_id,
            reason: params[:reason]
          ).call

          skip_default_audit_log!
          render json: {
            updated_count: result.fetch(:updated_count),
            check_print_queue: CheckPrintQueueService.new(pay_period: pay_period).call
          }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Pay period not found" }, status: :not_found
        rescue CheckNumberBatchCorrectionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "One or more check numbers are already in use for this company" }, status: :unprocessable_entity
        end
      end
    end
  end
end
