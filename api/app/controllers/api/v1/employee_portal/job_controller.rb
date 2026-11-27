# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # GET /api/v1/employee/job: "My job" for the open link, read only, so
      # view-only "Sign in as" sessions see it too. `job` is null for a
      # former job (not a 404, which the app reads as the link being gone).
      class JobController < BaseController
        def show
          response.headers["Cache-Control"] = "no-store"
          render json: { job: EmployeeProfiles::Job.new(employee_access_context).as_json }
        end
      end
    end
  end
end
