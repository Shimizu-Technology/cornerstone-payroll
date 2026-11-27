# frozen_string_literal: true

module Api
  module V1
    module Client
      class DepartmentsController < Api::V1::Admin::DepartmentsController
        include ClientPortalAccess

        skip_before_action :require_staff_access!
        before_action :require_client_portal_access!
        before_action :reject_read_only_workspace, only: %i[create update]

        private

        def reject_read_only_workspace
          return unless current_company.test_workspace_read_only?

          render json: { error: "This practice copy is read-only." }, status: :forbidden
        end
      end
    end
  end
end
