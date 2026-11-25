# frozen_string_literal: true

# Carries out one Clerk revocation the demo kill switch requested
# (EmployeeAppClerkRevocation), retried like RevokeEmployeeSessionsJob until
# Clerk confirms. The confirmed (or abandoned) outcome is audited on its own,
# separately from the stop's audit of what was requested, in the same
# transaction that records it, so an outcome is never recorded unaudited.
#
# Only the job that owns the row (the one its claim queued) does anything,
# and each attempt holds the row's lease (EmployeeAppClerkRevocation), so a
# duplicate job, or a second run of this one, never races an attempt or an
# outcome. An attempt records its outcome and releases its lease only under
# the lease token it took, so a run that somehow outlived its lease writes
# nothing; and a pass stops at PASS_DEADLINE, well inside the lease, and is
# rescheduled to carry on from where Clerk now stands.
#
# An invitation someone already accepted can't be revoked: the person has a
# Clerk account. The job ends that account's sessions instead (the login's
# bound Clerk user, or the one Clerk user with the invited address): every
# active session, however late it began, since the account came from a demo
# that is now stopped. It confirms only once a fresh listing finds none
# active. (A later sign-in still gets nothing: the stop revoked the link and
# turned the demo's app off.) If no single account can be found, the row
# ends needing follow-up, audited, and is never counted as confirmed.
class RevokeEmployeeAppClerkJob < ApplicationJob
  class RevocationFailed < StandardError; end

  CONFIRMED_ACTION = "employee_app_switch#clerk_revocation_confirmed"
  GAVE_UP_ACTION = "employee_app_switch#clerk_revocation_failed"
  FOLLOW_UP_ACTION = "employee_app_switch#clerk_revocation_needs_follow_up"
  # How long one pass may call Clerk. Each call has its own short timeouts,
  # so a pass ends well before its lease (ATTEMPT_LEASE) runs out.
  PASS_DEADLINE = 10.minutes
  DEADLINE_ERROR = "Clerk pass deadline reached; rescheduled"

  self.rls_mode = :system

  queue_as :default

  retry_on RevocationFailed, StandardError, wait: :polynomially_longer, attempts: 10 do |job, error|
    Rails.logger.error("[RevokeEmployeeAppClerkJob] GAVE UP on revocation #{job.arguments.first}: #{error.class}")
    TenantScope.as_system(reason: "Record an abandoned Clerk revocation") { job.give_up!(error) }
  end
  # Declared after the general retry so it handles a pass that ran out of
  # time: rescheduled soon, on its own count, not as a failed attempt.
  retry_on ClerkInvitationService::DeadlineReached, wait: 1.minute, attempts: 20 do |job, error|
    Rails.logger.error("[RevokeEmployeeAppClerkJob] GAVE UP on revocation #{job.arguments.first} after repeated deadlines")
    TenantScope.as_system(reason: "Record an abandoned Clerk revocation") { job.give_up!(error) }
  end

  def perform(revocation_id, clerk: ClerkInvitationService.new)
    revocation = EmployeeAppClerkRevocation.start_attempt!(revocation_id, job_id: job_id)
    return unless revocation

    lease = revocation.lease_token
    begin
      result = ClerkInvitationService.within_deadline(Time.current + PASS_DEADLINE) { call_clerk(revocation, clerk) }
      record_result!(revocation, lease, result)
    rescue ClerkInvitationService::DeadlineReached
      still_ours = revocation.finish!(job_id: job_id, lease_token: lease) { |row| row.update!(last_error: DEADLINE_ERROR) }
      # Rescheduled only while the row is still this attempt's.
      raise if still_ours
    ensure
      revocation.release_lease!(lease)
    end
  end

  # Takes the lease to record giving up, so a run that holds it (a newer
  # attempt) is never overruled; that run decides the outcome instead.
  def give_up!(error)
    revocation = EmployeeAppClerkRevocation.take_lease!(arguments.first, job_id: job_id)
    return unless revocation

    lease = revocation.lease_token
    begin
      revocation.finish!(job_id: job_id, lease_token: lease) do |row|
        row.update!(gave_up_at: Time.current, last_error: error.class.name.first(200))
        audit!(row, GAVE_UP_ACTION)
      end
    ensure
      revocation.release_lease!(lease)
    end
  end

  private

  def record_result!(revocation, lease, result)
    unless result[:follow_up] || result[:success]
      still_ours = revocation.finish!(job_id: job_id, lease_token: lease) do |row|
        row.update!(last_error: result[:error].to_s.first(200).presence || "Clerk didn't confirm")
      end
      # Retried only while the row is still this attempt's to finish.
      raise RevocationFailed, result[:error].to_s if still_ours
      return
    end

    revocation.finish!(job_id: job_id, lease_token: lease) do |row|
      if result[:follow_up]
        row.update!(follow_up_at: Time.current, outcome: result[:outcome], last_error: result[:error].to_s.first(200).presence)
        audit!(row, FOLLOW_UP_ACTION, sessions_ended: result[:revoked])
      else
        row.update!(confirmed_at: Time.current, outcome: result[:outcome], last_error: nil)
        audit!(row, CONFIRMED_ACTION, sessions_ended: result[:revoked])
      end
    end
  end

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

    # No creation-time cutoff: a session from after the stop (the invitation
    # accepted before Clerk heard of the revocation) ends too, and the pass
    # confirms only once none of the account's sessions is still active.
    clerk.revoke_user_sessions(clerk_id, created_before: nil, email: email).merge(outcome: "accepted_sessions_revoked")
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

  def audit!(revocation, action, sessions_ended: nil)
    AuditLog.record!(
      actor: AuditActor.system_job(self.class.name), user: nil, organization_id: revocation.organization_id,
      company_id: revocation.company_id, action: action, record_type: "EmployeeAppClerkRevocation", record_id: revocation.id,
      subject_name: revocation.kind, event_category: "security",
      metadata: { kind: revocation.kind, source: revocation.source, attempts: revocation.attempts,
                  requested_at: revocation.requested_at.utc.iso8601, user_id: revocation.user_id,
                  outcome: revocation.outcome, sessions_ended: sessions_ended }.compact
    )
  end
end
