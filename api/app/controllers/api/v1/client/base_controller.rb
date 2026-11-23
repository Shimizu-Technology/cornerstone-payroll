# frozen_string_literal: true

module Api
  module V1
    module Client
      class BaseController < ApplicationController
        include CompanyRlsScoped
        include Auditable
        include ExplicitCompanyAccess
        include ClientPortalAccess
        include BoundedListPagination

        before_action :require_client_portal_access!
        before_action :enforce_company_access!
      end
    end
  end
end
