# frozen_string_literal: true

# Carries out one Clerk revocation the demo kill switch requested
# (EmployeeAppClerkRevocation), retried like RevokeEmployeeSessionsJob until
# Clerk confirms. The confirmed (or abandoned) outcome is audited on its own,
# separately from the stop's audit of what was requested.
#
# An invitation someone already accepted can't be revoked: the person has a
# Clerk account. The job ends that account's sessions instead (the login's
# bound Clerk user, or the one Clerk user with the invited address) and
# confirms only once they are ended. If no single account can be found, the
# row ends needing follow-up, audited, and is never counted as confirmed.
class RevokeEmployeeAppClerkJob < ApplicationJob
  class RevocationFailed < StandardError; end

  CONFIRMED_ACTION = "employee_app_switch#clerk_revocation_confirmed"
  GAVE_UP_ACTION = "employee_app_switch#clerk_revocation_failed"
  FOLLOW_UP_ACTION = "employee_app_switch#clerk_revocation_needs_follow_up"

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
    if result[:follow_up]
      revocation.update!(follow_up_at: Time.current, outcome: result[:outcome], last_error: result[:error].to_s.first(200).presence)
      return audit!(revocation, FOLLOW_UP_ACTION)
    end
    unless result[:success]
      revocation.update!(last_error: result[:error].to_s.first(200).presence || "Clerk didn't confirm")
      raise RevocationFailed, result[:error].to_s
    end

    revocation.update!(confirmed_at: Time.current, outcome: result[:outcome], last_error: nil)
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
    when "invitation" then revoke_invitation(revocation, clerk)
    when "sessions" then revoke_sessions(revocation, clerk)
    else { success: false, error: "Unknown revocation kind" }
    end
  end

  # An invitation that is already closed counts as confirmed; one already
  # accepted is confirmed only once the resulting account's sessions end.
  def revoke_invitation(revocation, clerk)
    case clerk.invitation_status(revocation.target)
    when "revoked", "expired", :not_found then { success: true, outcome: "invitation_closed" }
    when "accepted" then revoke_accepted_invitation(revocation, clerk)
    else clerk.revoke_invitation(revocation.target).merge(outcome: "invitation_revoked")
    end
  end

  def revoke_accepted_invitation(revocation, clerk)
    user = revocation.user
    clerk_id = bound_clerk_id(user)
    # Unbound: the staging tester gate checks the address it was made for.
    email = user&.email unless clerk_id
    unless clerk_id
      matches = user&.email.present? ? clerk.users_with_email(user.email) : []
      return { success: false, error: "Clerk users couldn't be listed" } if matches.nil?
      unless matches.one?
        return { follow_up: true, outcome: "accepted_account_not_found",
                 error: "Invitation accepted; #{matches.size} Clerk accounts have the invited address" }
      end

      clerk_id = matches.first["id"]
    end

    clerk.revoke_user_sessions(clerk_id, created_before: EmployeeLinks::SessionFence.cutoff(revocation.requested_at),
      email: email).merge(outcome: "accepted_sessions_revoked")
  end

  def revoke_sessions(revocation, clerk)
    clerk_id = bound_clerk_id(User.find_by(id: revocation.target.to_i))
    # A login that never bound a Clerk account has no sessions to end.
    return { success: true, outcome: "no_bound_account" } unless clerk_id

    clerk.revoke_user_sessions(clerk_id, created_before: EmployeeLinks::SessionFence.cutoff(revocation.requested_at))
      .merge(outcome: "sessions_revoked")
  end

  def bound_clerk_id(user)
    clerk_id = user&.clerk_id
    clerk_id if clerk_id.present? && !clerk_id.start_with?("pending_")
  end

  def audit!(revocation, action)
    AuditLog.record!(
      actor: AuditActor.system_job(self.class.name), user: nil, organization_id: revocation.organization_id,
      company_id: revocation.company_id, action: action, record_type: "EmployeeAppClerkRevocation", record_id: revocation.id,
      subject_name: revocation.kind, event_category: "security",
      metadata: { kind: revocation.kind, source: revocation.source, attempts: revocation.attempts,
                  requested_at: revocation.requested_at.utc.iso8601, user_id: revocation.user_id,
                  outcome: revocation.outcome }.compact
    )
  end
end
