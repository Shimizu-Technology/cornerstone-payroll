# frozen_string_literal: true

module QuickbooksHistory
  module ClientBootstrapAuthorization
    ERROR_MESSAGE = "An attributed manager or administrator with client access is required"

    module_function

    def ensure_authorized!(actor:, company_id:)
      return if actor&.payroll_access_allowed? && actor.can_access_company?(company_id) &&
        StaffRolePolicy.allowed?(actor, :manage_client_configuration)

      raise ArgumentError, ERROR_MESSAGE
    end
  end
end
