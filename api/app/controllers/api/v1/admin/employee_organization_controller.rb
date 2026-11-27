# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeOrganizationController < BaseController
        include EmployeeOrganizationActions

        private

        def authorize_organization_write!
          revalidate_current_company_write_access!(capability: :payroll_operations)
        end
      end
    end
  end
end
