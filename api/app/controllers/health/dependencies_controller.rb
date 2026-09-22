# frozen_string_literal: true

module Health
  # Public monitoring endpoint. Keep its payload intentionally minimal; the
  # detailed report is for application logs and console-based incident triage.
  class DependenciesController < ActionController::API
    def show
      report = DependencyHealth.new.run
      response.headers["Cache-Control"] = "no-store"
      render json: { status: report.ready? ? "ok" : "degraded" },
        status: report.ready? ? :ok : :service_unavailable
    end
  end
end
