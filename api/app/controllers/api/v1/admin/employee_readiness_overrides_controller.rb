# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeReadinessOverridesController < BaseController
        include StaffEmployeeLifecycleAccess
        include RecentVerification

        before_action :require_override_verification
        before_action :skip_default_audit_log!

        rescue_from AdminOverrideService::AccessDenied do |error|
          render json: { error: error.message }, status: :forbidden
        end

        rescue_from ArgumentError, ActiveRecord::RecordInvalid, EmployeeW4ElectionChangeService::Error do |error|
          render json: { error: error.message }, status: :unprocessable_content
        end

        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "Employee, pay period, or readiness override not found" }, status: :not_found
        end

        def create
          override = manager.grant!(reason: params[:reason], pay_period_id: params[:pay_period_id],
            expires_on: params[:expires_on], default_w4_acknowledged: params[:default_w4_acknowledged].in?([ true, "true" ]))
          render json: { data: override }, status: :created
        end

        def destroy
          override = manager.revoke!(override_id: params[:override_id], reason: params[:reason])
          render json: { data: override }
        end

        def clear_readiness_gate
          employee = manager.clear_gate!(reason: params[:reason])
          render json: { data: { id: employee.id, readiness_gate_enforced: employee.readiness_gate_enforced? } }
        end

        private

        def require_override_verification
          require_direct_recent_verification!(impersonation_error: "Exit Sign in as before changing employee readiness.")
        end

        def manager
          EmployeeReadinessOverrides::Manage.new(company_id: current_company_id, employee_id: params[:id],
            actor: current_user, verified: MfaPolicy.recently_step_up_verified?(@clerk_token_payload),
            impersonated: impersonated_session?)
        end
      end
    end
  end
end
