# frozen_string_literal: true

module ClientComponentHistoryErrors
  extend ActiveSupport::Concern

  included do
    rescue_from PayrollComponentMirrors::AmbiguousHistoryError, PayrollInsuranceComponents::AmbiguousHistoryError,
      with: :render_component_history_error
  end

  private

  def render_component_history_error(error)
    Rails.logger.warn("Client payroll #{controller_name}##{action_name} for company #{current_company_id}: #{error.class}: #{error.message}")
    Rails.error.report(error, handled: true, context: { company_id: current_company_id, action: action_name })
    render json: { error: "Payroll details are unavailable right now. Contact Cornerstone." }, status: :unprocessable_entity
  end
end
