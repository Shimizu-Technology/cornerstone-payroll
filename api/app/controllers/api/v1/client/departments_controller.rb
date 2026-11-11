# frozen_string_literal: true

module Api
  module V1
    module Client
      class DepartmentsController < Api::V1::Admin::DepartmentsController
        include ClientPortalAccess

        skip_before_action :require_staff_access!
        before_action :require_client_portal_access!
      end
    end
  end
end
