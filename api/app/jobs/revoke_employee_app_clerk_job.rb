# frozen_string_literal: true

# Carries out one Clerk revocation the demo kill switch requested
# (EmployeeAppClerkRevocation), retried like RevokeEmployeeSessionsJob until
# Clerk confirms. The confirmed (or abandoned) outcome is audited on its own,
# separately from the stop's audit of what was requested.
class RevokeEmployeeAppClerkJob < ApplicationJob
  class RevocationFailed < StandardError; end

  CONFIRMED_ACTION = "employee_app_switch#clerk_revocation_confirmed"
  GAVE_UP_ACTION = "employee_app_switch#clerk_revocation_failed"

  self.rls_mode = :system

  queue_as :default

  retry_on RevocationFailed, StandardError, wait: :polynomially_longer, attempts: 10 do |job, error|
    Rails.logger.error("[RevokeEmployeeAppClerkJob] GAVE UP on revocation #{job.arguments.first}: #{error.class}")
    TenantScope.as_system(reason: "Record an abandoned Clerk revocation") { job.give_up!(error) }
  end

  def perform(revocation_id, clerk: ClerkInvitationService.new)
    revocation = EmployeeAppClerkRevocation.find_by(id: revocation_id)
    return unless revocation&.pending?

    revocation.update!(attempts: revocation.attempts + 1)
    result = call_clerk(revocation, clerk)
    unless result[:success]
      revocation.update!(last_error: result[:error].to_s.first(200).presence || "Clerk didn't confirm")
      raise RevocationFailed, result[:error].to_s
    end

    revocation.update!(confirmed_at: Time.current, last_error: nil)
    audit!(revocation, CONFIRMED_ACTION)
  end

  def give_up!(error)
    revocation = EmployeeAppClerkRevocation.find_by(id: arguments.first)
    return unless revocation&.pending?

    revocation.update!(gave_up_at: Time.current, last_error: error.class.name.first(200))
    audit!(revocation, GAVE_UP_ACTION)
  end

  private

  def call_clerk(revocation, clerk)
    case revocation.kind
    when "invitation" then revoke_invitation(revocation.target, clerk)
    when "sessions" then revoke_sessions(revocation, clerk)
    else { success: false, error: "Unknown revocation kind" }
    end
  end

  # An invitation that is already closed counts as confirmed.
  def revoke_invitation(invitation_id, clerk)
    case clerk.invitation_status(invitation_id)
    when "revoked", "expired", :not_found then { success: true }
    when "accepted" then { success: true, accepted: true }
    else clerk.revoke_invitation(invitation_id)
    end
  end

  def revoke_sessions(revocation, clerk)
    user = User.find_by(id: revocation.target.to_i)
    clerk_id = user&.clerk_id
    # A login that never bound a Clerk account has no sessions to end.
    return { success: true } if clerk_id.blank? || clerk_id.start_with?("pending_")

    clerk.revoke_user_sessions(clerk_id, created_before: EmployeeLinks::SessionFence.cutoff(revocation.requested_at))
  end

  def audit!(revocation, action)
    AuditLog.record!(
      actor: AuditActor.system_job(self.class.name), user: nil, organization_id: revocation.organization_id,
      company_id: revocation.company_id, action: action, record_type: "EmployeeAppClerkRevocation", record_id: revocation.id,
      subject_name: revocation.kind, event_category: "security",
      metadata: { kind: revocation.kind, source: revocation.source, attempts: revocation.attempts,
                  requested_at: revocation.requested_at.utc.iso8601, user_id: revocation.user_id }.compact
    )
  end
end
