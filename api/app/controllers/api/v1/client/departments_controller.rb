# frozen_string_literal: true

module Api
  module V1
    module Client
      class DepartmentsController < Api::V1::Admin::DepartmentsController
        skip_before_action :require_staff_access!
        before_action :require_client_portal_access!

        private

        def require_client_portal_access!
          return if current_user&.staff_member? || current_user&.client?

          render json: { error: "Client portal access required" }, status: :forbidden
        end
      end
    end
  end
end
