# frozen_string_literal: true

module ConnectedPayrollControl
  extend ActiveSupport::Concern

  private

  def require_connected_payroll!
    return if ConnectedPayrollMode.enabled?

    response.headers["Retry-After"] = "60"
    render json: { error: ConnectedPayrollMode::MESSAGE, connected_payroll: ConnectedPayrollMode.capability }, status: :service_unavailable
  end
end
