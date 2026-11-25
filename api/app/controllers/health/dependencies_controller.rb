# frozen_string_literal: true

module Health
  # Public monitoring endpoint. Keep its payload intentionally minimal; the
  # detailed report is for application logs and console-based incident triage.
  class DependenciesController < ActionController::API
    def show
      report = DependencyHealth.new.run
      # On the employee service, also record what it observes about itself
      # for the staff switch readiness checks (M4-9d). Throttled; never fails.
      EmployeeServiceObservation.record_current_process!(dependencies_healthy: report.ready?)
      response.headers["Cache-Control"] = "no-store"
      render json: { status: report.ready? ? "ok" : "degraded" },
        status: report.ready? ? :ok : :service_unavailable
    end
  end
end
