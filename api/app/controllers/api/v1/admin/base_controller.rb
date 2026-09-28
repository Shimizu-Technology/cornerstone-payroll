# frozen_string_literal: true

module Api
  module V1
    module Admin
      class BaseController < ApplicationController
        include Auditable

        before_action :require_staff_access!
        before_action :enforce_finance_context!
        before_action :enforce_company_access!
        before_action :enforce_test_workspace_access!
        before_action :enforce_test_workspace_safety!
        before_action :enforce_high_impact_role_policy!

        private

        def enforce_finance_context!
          return unless finance_request?

          raw_organization_id = request.headers["X-Organization-Id"].presence
          if raw_organization_id
            unless raw_organization_id.to_s.match?(/\A[1-9]\d*\z/)
              return render json: { error: "Invalid organization context" }, status: :unprocessable_entity
            end

            organization = Organization.find_by(id: raw_organization_id.to_i)
            return render json: { error: "Organization not found" }, status: :not_found unless organization
            unless current_user.super_admin? || organization.id == current_user.organization_id
              return render json: { error: "You do not have access to this organization" }, status: :forbidden
            end
          end

          raw_company_id = request.headers["X-Company-Id"].presence
          return unless raw_company_id

          unless raw_company_id.to_s.match?(/\A[1-9]\d*\z/)
            return render json: { error: "Invalid company context" }, status: :unprocessable_entity
          end

          company = Company.find_by(id: raw_company_id.to_i)
          return render json: { error: "Company not found" }, status: :not_found unless company
          unless current_user.can_access_company?(company.id)
            return render json: { error: "You do not have access to this company" }, status: :forbidden
          end
          if raw_organization_id && company.organization_id != raw_organization_id.to_i
            render json: { error: "Company does not belong to the selected organization" }, status: :unprocessable_entity
          end
        end

        # Allow organization admins, managers, and accountants to access the admin namespace.
        def require_staff_access!
          unless StaffRolePolicy.allowed?(current_user, :staff_workspace)
            render json: { error: "Staff access required" }, status: :forbidden
          end
        end

        def enforce_high_impact_role_policy!
          capability = StaffRolePolicy.capability_for(
            controller_path: controller_path,
            action_name: action_name
          )
          return unless capability

          require_capability!(capability)
        end

        def enforce_test_workspace_access!
          return unless current_company&.test_workspace?

          capability = StaffRolePolicy.capability_for(
            controller_path: controller_path,
            action_name: action_name
          )
          return if TestWorkspaceAccessPolicy.allowed?(
            user: current_user,
            company: current_company,
            request_method: request.request_method,
            capability: capability
          )

          render json: {
            error: "Your test workspace access does not allow this action"
          }, status: :forbidden
        end

        def enforce_test_workspace_safety!
          return unless current_company&.test_workspace?

          unless current_company.migration_rehearsal_status == "ready"
            return render json: {
              error: "This test workspace is still being prepared. Try again after its verified copy is ready."
            }, status: :conflict
          end
          return unless TestWorkspaceSafetyPolicy.blocked?(controller_path: controller_path, action_name: action_name)

          render json: {
            error: "This action is unavailable in a test workspace. Test workspaces cannot issue checks, move money, commit payroll, or produce filing-ready records."
          }, status: :forbidden
        end

        def require_capability!(capability, error: nil)
          return if StaffRolePolicy.allowed?(current_user, capability)

          render json: {
            error: error || StaffRolePolicy.error_message(capability)
          }, status: :forbidden
        end

        def require_historical_payroll_enabled!
          return if current_company&.historical_payroll_enabled?

          render json: {
            error: "Historical payroll is not enabled for this client",
            details: {}
          }, status: :forbidden
        end

        # Staff must stay inside the companies granted by their platform role.
        def enforce_company_access!
          return if current_user.nil?

          unless current_user.can_access_company?(current_company_id)
            render json: { error: "You do not have access to this company" }, status: :forbidden
          end
        end

        # Backward-compatible alias
        def require_admin_or_manager!
          require_manager_or_admin!
        end

        def require_manager_or_admin!
          require_capability!(:manage_client_configuration)
        end
      end
    end
  end
end
