# frozen_string_literal: true

class PayrollFilingResponsibilityPolicy
  class NotAuthorized < StandardError; end

  ERROR_MESSAGE = "Filing review access required"

  def self.authorize_record!(actor:, company:)
    allowed = actor&.payroll_access_allowed? &&
      actor.can_access_company?(company.id) &&
      StaffRolePolicy.allowed?(actor, :manage_filing_review)
    return if allowed

    raise NotAuthorized, ERROR_MESSAGE
  end
end
