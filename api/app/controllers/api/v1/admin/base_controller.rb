# frozen_string_literal: true

module Api
  module V1
    module Admin
      class BaseController < ApplicationController
        before_action :require_staff_access!
        before_action :require_manager_or_admin!, unless: :read_only_request?

        private

        # Allow admin, manager, and accountant roles to access the admin namespace.
        # Accountants have restricted company scope enforced via resolve_company_id.
        def require_staff_access!
          unless current_user&.admin? || current_user&.manager? || current_user&.accountant?
            render json: { error: "Staff access required" }, status: :forbidden
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

        def read_only_request?
          request.get? || request.head?
        end
      end
    end
  end
end
