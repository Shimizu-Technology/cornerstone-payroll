# frozen_string_literal: true

module Api
  module V1
    module Client
      class DepartmentsController < Api::V1::Admin::DepartmentsController
        include ClientPortalAccess

        skip_before_action :require_staff_access!
        before_action :require_client_portal_access!

        private

        def authorize_department_write!
          revalidate_client_company_write_access!
        end
      end
    end
  end
end
