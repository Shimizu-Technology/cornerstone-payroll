# frozen_string_literal: true

module Api
  module V1
    module Client
      class EmployeeOrganizationController < BaseController
        include EmployeeOrganizationActions

        private

        def authorize_organization_write!
          revalidate_client_company_write_access!
        end
      end
    end
  end
end
