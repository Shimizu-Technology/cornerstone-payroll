# frozen_string_literal: true

# Ends a closed employee app login's Clerk sessions (D12), retried until Clerk
# confirms. The login is already deactivated, which refuses every API call;
# this stops the browser session too.
class RevokeEmployeeSessionsJob < ApplicationJob
  class RevocationFailed < StandardError; end

  self.rls_mode = :exempt_tables_only

  queue_as :default

  retry_on RevocationFailed, StandardError, wait: :polynomially_longer, attempts: 10

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user&.clerk_id.present? && !user.clerk_id.start_with?("pending_")
    return if user.payroll_access_allowed?

    result = ClerkInvitationService.new.revoke_user_sessions(user.clerk_id)
    raise RevocationFailed, result[:error].to_s unless result[:success]
  end
end
