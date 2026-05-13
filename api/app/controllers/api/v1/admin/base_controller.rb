# frozen_string_literal: true

module Api
  module V1
    module Admin
      class BaseController < ApplicationController
        before_action :require_staff_access!
        before_action :enforce_company_access!

        private

        # Allow organization admins, managers, and accountants to access the admin namespace.
        def require_staff_access!
          unless current_user&.staff_member?
            render json: { error: "Staff access required" }, status: :forbidden
          end
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
          unless current_user&.organization_admin? || current_user&.manager?
            render json: { error: "Manager or admin access required" }, status: :forbidden
          end
        end
      end
    end
  end
end
