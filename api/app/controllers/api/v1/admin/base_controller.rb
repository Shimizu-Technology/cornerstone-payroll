# frozen_string_literal: true

module Api
  module V1
    module Admin
      class BaseController < ApplicationController
        before_action :require_staff_access!
        before_action :enforce_company_access!

        private

        # Allow admin, manager, and accountant roles to access the admin namespace.
        def require_staff_access!
          unless current_user&.admin? || current_user&.manager? || current_user&.accountant?
            render json: { error: "Staff access required" }, status: :forbidden
          end
        end

        # Accountants can only access companies they're assigned to.
        # Super admins and regular admins bypass this check.
        def enforce_company_access!
          return if current_user&.super_admin?
          return if current_user&.admin?
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
          unless current_user&.admin? || current_user&.manager?
            render json: { error: "Manager or admin access required" }, status: :forbidden
          end
        end
      end
    end
  end
end
