# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # GET /api/v1/employee/help: the company's Help contacts (M4-9a), read
      # only, for signed-in employees of that company. They're never part of
      # the public branding response. An empty list means the client hasn't
      # set them up yet, and the app says "Ask your manager".
      class HelpController < BaseController
        def show
          response.headers["Cache-Control"] = "no-store"
          contacts = CompanyHelpContact.where(company_id: employee_access_context.company_id).order(:position, :id)
          render json: { help_contacts: contacts.map(&:as_help_json) }
        end
      end
    end
  end
end
