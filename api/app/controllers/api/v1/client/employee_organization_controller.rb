# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeeOrganizationController < BaseController
        include EmployeeOrganizationActions

        private

        def authorize_organization_write!
          actor = User.lock.find(current_user.id)
          return if actor.client? && !actor.client_viewer? && actor.can_access_company?(current_company.id) &&
            !current_company.test_workspace_read_only?

          raise ActiveRecord::RecordNotFound
        end
      end
    end
  end
end
