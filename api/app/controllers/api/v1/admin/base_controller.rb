# frozen_string_literal: true

module Api
  module V1
    module Admin
      class BaseController < ApplicationController
        include Auditable

        before_action :require_staff_access!
        before_action :enforce_company_access!
        before_action :enforce_high_impact_role_policy!

        private

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

        def require_capability!(capability, error: nil)
          return if StaffRolePolicy.allowed?(current_user, capability)

          render json: {
            error: error || StaffRolePolicy.error_message(capability)
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
