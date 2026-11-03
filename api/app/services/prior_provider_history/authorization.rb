# frozen_string_literal: true

module PriorProviderHistory
  # Recording a client's already-paid history is ordinary payroll work: the
  # same staff who run and commit that client's payroll may do it end to end.
  module Authorization
    class NotAuthorized < StandardError; end

    CAPABILITY = :payroll_operations
    ERROR_MESSAGE = "Payroll staff with access to this client are required"

    module_function

    def allowed?(actor, company)
      return false unless actor && company

      actor.payroll_access_allowed? && actor.can_access_company?(company.id) &&
        StaffRolePolicy.allowed?(actor, CAPABILITY, company: company)
    end

    # Call with lock: true inside the business transaction, after its row locks.
    # Return a fresh actor so attribution and policy never reuse cached grants.
    def ensure_authorized!(actor:, company_id:, lock: false)
      if lock
        actor = User.lock.find_by(id: actor&.id)
        CompanyAssignment.where(company_id: company_id, user_id: actor&.id).lock.load
      end
      return actor if allowed?(actor, Company.find_by(id: company_id))

      raise NotAuthorized, ERROR_MESSAGE
    end
  end
end
