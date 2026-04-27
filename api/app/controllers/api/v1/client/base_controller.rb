# frozen_string_literal: true

module Api
  module V1
    module Client
      class BaseController < ApplicationController
        before_action :require_client_portal_access!
        before_action :enforce_company_access!

        private

        def require_client_portal_access!
          return if current_user&.admin? || current_user&.manager? || current_user&.accountant? || current_user&.client?

          render json: { error: "Client portal access required" }, status: :forbidden
        end

        def enforce_company_access!
          return if current_user.nil?
          return if current_user.admin?

          unless current_user.can_access_company?(current_company_id)
            render json: { error: "You do not have access to this company" }, status: :forbidden
          end
        end
      end
    end
  end
end
