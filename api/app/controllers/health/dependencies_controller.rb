# frozen_string_literal: true

module Health
  # Public monitoring endpoint. Keep its payload intentionally minimal; the
  # detailed report is for application logs and console-based incident triage.
  #
  # M4-9d: when Payroll web's switch readiness asks with a nonce and proof
  # of the shared secret, the employee service also returns a signed
  # statement about its own process (EmployeeAppSwitch::ServiceAttestation).
  # Anyone else gets only the status.
  class DependenciesController < ActionController::API
    def show
      report = DependencyHealth.new.run
      response.headers["Cache-Control"] = "no-store"
      body = { status: report.ready? ? "ok" : "degraded" }
      attestation = attestation_for(report)
      body[:attestation] = attestation if attestation
      render json: body, status: report.ready? ? :ok : :service_unavailable
    end

    private

    def attestation_for(report)
      attestation = EmployeeAppSwitch::ServiceAttestation
      nonce = request.headers[attestation::NONCE_HEADER]
      return unless attestation.valid_request?(nonce, request.headers[attestation::PROOF_HEADER])

      attestation.sign(nonce: nonce, dependencies_healthy: report.ready?)
    end
  end
end
