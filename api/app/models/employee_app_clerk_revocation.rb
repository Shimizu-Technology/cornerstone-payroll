# frozen_string_literal: true

# A Clerk revocation the demo kill switch requested (M4-9d): a pending
# sign-up invitation, or every session of an employee-only demo login. The
# row is the durable request; RevokeEmployeeAppClerkJob retries it until
# Clerk confirms (confirmed_at), the retries run out (gave_up_at), or Clerk's
# answer needs a person to check it (follow_up_at; an invitation already
# accepted whose sign-in couldn't be found). Each outcome is audited
# separately from the request, in the same transaction that records it.
#
# One job owns a row at a time (job_id). Queuing claims the row atomically
# (enqueue!): a conditional UPDATE that only one caller can win, so a repeat
# stop and RetryEmployeeAppClerkRevocationsJob never both queue it, and a
# job the sweep replaced (say it was only waiting in a backlog) finds it no
# longer owns the row and does nothing. The claim is confirmed
# (submitted_at) only once the job is really queued; a claim whose enqueue
# never happened (the process died in between) is re-queued by the sweep
# after UNSUBMITTED_AFTER.
#
# Each attempt takes a lease (leased_until) the same way, so two runs of the
# owning job can't call Clerk or record an outcome at once. The lease is
# fenced by a token written when it is taken (lease_token): recording an
# outcome and releasing the lease both match that token, so a run that
# outlived its lease and lost it to a newer one writes nothing.
class EmployeeAppClerkRevocation < ApplicationRecord
  KINDS = %w[invitation sessions].freeze
  SOURCE_DEMO_STOP = "demo_stop"
  # A pending row never queued this long after its request, or untouched
  # this long (longer than the job's slowest retry wait), has no live job.
  UNQUEUED_AFTER = 5.minutes
  # A claim not confirmed as queued this long after it was made never
  # reached the queue.
  UNSUBMITTED_AFTER = 5.minutes
  LOST_AFTER = 6.hours
  # Longer than a Clerk pass may run (RevokeEmployeeAppClerkJob::PASS_DEADLINE);
  # an attempt that dies without releasing its lease is left to the sweep
  # once the row is stale.
  ATTEMPT_LEASE = 15.minutes

  belongs_to :organization
  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :requested_by, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :target, :source, :requested_at, presence: true

  scope :pending, -> { where(confirmed_at: nil, gave_up_at: nil, follow_up_at: nil) }
  # Pending rows a repeat stop queues: never queued (or the enqueue failed).
  scope :unqueued, -> { pending.where(enqueued_at: nil) }
  # Pending rows with no job to carry them out, and no attempt in progress:
  # never queued, claimed but never confirmed as queued, or untouched too
  # long.
  scope :stale, lambda { |now = Time.current|
    pending.where("leased_until IS NULL OR leased_until < ?", now)
      .where("(enqueued_at IS NULL AND requested_at < :unqueued) " \
             "OR (enqueued_at IS NOT NULL AND submitted_at IS NULL AND enqueued_at < :unsubmitted) " \
             "OR updated_at < :lost",
        unqueued: now - UNQUEUED_AFTER, unsubmitted: now - UNSUBMITTED_AFTER, lost: now - LOST_AFTER)
  }

  # Records the request unless the same one is still pending. Returns the
  # new row, or nil for a duplicate. Run inside the caller's transaction;
  # enqueue the job after commit.
  def self.request!(kind:, target:, organization:, company:, source:, requested_by:, user: nil, now: Time.current)
    return nil if pending.exists?(kind: kind, target: target.to_s)

    transaction(requires_new: true) do
      create!(kind: kind, target: target.to_s, organization: organization, company: company, user: user,
        source: source, requested_by: requested_by, requested_at: now)
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # Queues a job for each row still in the scope the caller read it from
  # (unqueued by default; the sweep passes stale: true), claiming each row
  # first: the UPDATE matches only while the row is still in that scope and
  # still has the owner it was read with, so of two callers racing for a
  # row exactly one queues it. A failed enqueue hands the row back, so the
  # sweep (or a repeat stop) queues it again; a successful one is confirmed
  # (submitted_at), so a claim left unconfirmed by a crash is the sweep's
  # after UNSUBMITTED_AFTER. Returns the ids queued.
  def self.enqueue!(ids, now: Time.current, stale: false)
    scope = stale ? self.stale(now) : unqueued
    scope.where(id: ids).order(:id).pluck(:id, :job_id).filter_map do |id, owner|
      id if claim_and_enqueue(scope, id, owner, now)
    end
  end

  def self.claim_and_enqueue(scope, id, owner, now)
    job = RevokeEmployeeAppClerkJob.new(id)
    claimed = scope.where(id: id, job_id: owner)
      .update_all(job_id: job.job_id, enqueued_at: now, submitted_at: nil, updated_at: now)
    return false unless claimed == 1
    raise ActiveJob::EnqueueError, "not queued" unless job.enqueue

    confirm_submitted(id, job.job_id)
    true
  rescue StandardError => error
    Rails.logger.error("[EmployeeAppClerkRevocation] could not queue revocation #{id}: #{error.class}")
    where(id: id, job_id: job&.job_id).update_all(job_id: owner, enqueued_at: nil, submitted_at: nil) if job
    false
  end
  private_class_method :claim_and_enqueue

  # The job is queued; a failure to record that only means the sweep
  # re-queues the row later, and the queued job then no longer owns it.
  def self.confirm_submitted(id, job_id)
    where(id: id, job_id: job_id).update_all(submitted_at: Time.current)
  rescue StandardError => error
    Rails.logger.error("[EmployeeAppClerkRevocation] could not confirm queued revocation #{id}: #{error.class}")
  end
  private_class_method :confirm_submitted

  # Starts an attempt for this job: counts it and takes the lease. See
  # take_lease!.
  def self.start_attempt!(id, job_id:, now: Time.current)
    take_lease!(id, job_id: job_id, now: now, attempt: true)
  end

  # Takes the lease for this job, only if the row is still pending, this job
  # owns it (or no job has claimed it yet), and no other attempt holds the
  # lease, with a fresh lease_token for this attempt (counted when attempt:
  # is true). Returns the row, holding that token in memory (held_lease),
  # or nil. The caller passes held_lease to finish! and release_lease!.
  #
  # The token is the one generated here, never one read back: the row is
  # reloaded by id and that token together, so a run that stalls between
  # taking the lease and reloading it, and loses the lease to a newer
  # attempt meanwhile, gets nil rather than the newer attempt's token.
  def self.take_lease!(id, job_id:, now: Time.current, attempt: false)
    token = SecureRandom.hex(16)
    counted = attempt ? "attempts + 1" : "attempts"
    taken = pending.where(id: id).where("job_id IS NULL OR job_id = ?", job_id)
      .where("leased_until IS NULL OR leased_until < ?", now)
      .update_all([ "attempts = #{counted}, leased_until = ?, lease_token = ?, updated_at = ?", now + ATTEMPT_LEASE, token, now ])
    return unless taken == 1

    leased_row(id, token)&.tap { |row| row.held_lease = token }
  end

  def self.leased_row(id, token)
    find_by(id: id, lease_token: token)
  end
  private_class_method :leased_row

  # The lease token this attempt generated (set by take_lease!), kept apart
  # from the lease_token column so a later reload can't swap in another
  # attempt's token.
  attr_accessor :held_lease

  # Records an outcome under the row lock, only while the row is still
  # pending, owned by this job, and leased to this attempt (lease_token): a
  # locking read that matches all three, so a run that lost its lease gets
  # nothing. Yields the locked row; whatever the block writes (the outcome
  # and its audit) commits or rolls back together. Returns the block's
  # value, or nil when the row was no longer this attempt's.
  def finish!(job_id:, lease_token:)
    return nil if lease_token.blank?

    transaction do
      row = self.class.pending.where(id: id, lease_token: lease_token)
        .where("job_id IS NULL OR job_id = ?", job_id).lock.first
      yield row if row
    end
  end

  # Ends this attempt's lease; a lease a newer attempt took is left alone.
  def release_lease!(lease_token)
    return 0 if lease_token.blank?

    self.class.where(id: id, lease_token: lease_token).update_all(leased_until: nil, lease_token: nil)
  end

  def pending?
    confirmed_at.nil? && gave_up_at.nil? && follow_up_at.nil?
  end
end
