# frozen_string_literal: true

class RevokePayrollAccessJob < ApplicationJob
  queue_as :default

  # A deactivated account must not keep an existing Cable subscription just
  # because Redis or the Cable adapter was temporarily unavailable. Production
  # uses Solid Queue by default, so retries survive web-process restarts.
  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user
    return if user.payroll_access_allowed?

    PayrollAccess::SessionRevoker.disconnect_user(user)
  end
end
