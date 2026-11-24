# frozen_string_literal: true

module EmployeeLinks
  # Sessions from before an employee-only login was deactivated stay refused
  # for good, even after the login is reactivated (M4-2, D12): a token counts
  # only if its first factor was verified after users.deactivated_at.
  #
  # Clerk tokens are refreshed every minute, so iat alone says nothing about
  # when the person signed in. fva[0] is the minutes since the first factor
  # was verified; iat minus (fva[0] + 1) minutes is the earliest that could
  # have been. A token without both fails closed, for fenced logins only.
  module SessionFence
    module_function

    def first_factor_verified_at(payload)
      return unless payload.is_a?(Hash)

      iat = payload["iat"]
      age = payload["fva"].is_a?(Array) ? payload["fva"].first : nil
      return unless iat.is_a?(Integer) && age.is_a?(Integer) && age >= 0

      Time.zone.at(iat - ((age + 1) * 60))
    end

    def fenced?(user, payload)
      return false unless user&.portal_employee? && user.deactivated_at

      verified_at = first_factor_verified_at(payload)
      verified_at.nil? || verified_at <= user.deactivated_at
    end
  end
end
