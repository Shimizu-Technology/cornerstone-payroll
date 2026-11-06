# frozen_string_literal: true

module QuickbooksHistory
  module ClientBootstrapAuthorization
    class NotAuthorized < StandardError; end

    ERROR_MESSAGE = "An attributed manager or administrator with client access is required"

    module_function

    # Call with lock: true inside the business transaction, after its row locks.
    # Return a fresh actor so attribution and policy never reuse cached grants.
    def ensure_authorized!(actor:, company_id:, lock: false)
      if lock
        actor = User.lock.find_by(id: actor&.id)
        CompanyAssignment.where(company_id: company_id, user_id: actor&.id).lock.load
      end
      return actor if actor&.payroll_access_allowed? && actor.can_access_company?(company_id) &&
        StaffRolePolicy.allowed?(actor, :manage_client_configuration, company: Company.find_by(id: company_id))

      raise NotAuthorized, ERROR_MESSAGE
    end
  end
end
