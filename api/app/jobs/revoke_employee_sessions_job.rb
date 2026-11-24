# frozen_string_literal: true

# Ends a closed employee app login's Clerk sessions (D12), retried until Clerk
# confirms. The login is already deactivated, which refuses every API call;
# this stops the browser session too.
#
# It ends every session that began at or before the closure even if the
# login was reactivated meanwhile (a rehire), so no pre-closure session comes
# back; those are also refused by EmployeeLinks::SessionFence.
class RevokeEmployeeSessionsJob < ApplicationJob
  class RevocationFailed < StandardError; end

  self.rls_mode = :exempt_tables_only

  queue_as :default

  retry_on RevocationFailed, StandardError, wait: :polynomially_longer, attempts: 10

  def perform(user_id, closed_at = nil)
    user = User.find_by(id: user_id)
    return unless user&.clerk_id.present? && !user.clerk_id.start_with?("pending_")

    cutoff = closed_at.present? ? Time.zone.parse(closed_at.to_s) : user.deactivated_at
    return if cutoff.nil? && user.payroll_access_allowed?

    result = ClerkInvitationService.new.revoke_user_sessions(user.clerk_id, created_before: cutoff)
    raise RevocationFailed, result[:error].to_s unless result[:success]
  end
end
