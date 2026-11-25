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
# longer owns the row and does nothing. Each attempt takes a lease
# (leased_until) the same way, so two runs of the owning job can't call
# Clerk or record an outcome at once.
class EmployeeAppClerkRevocation < ApplicationRecord
  KINDS = %w[invitation sessions].freeze
  SOURCE_DEMO_STOP = "demo_stop"
  # A pending row never queued this long after its request, or untouched
  # this long (longer than the job's slowest retry wait), has no live job.
  UNQUEUED_AFTER = 5.minutes
  LOST_AFTER = 6.hours
  # Longer than one full Clerk pass takes; an attempt that dies without
  # releasing its lease is left to the sweep once the row is stale.
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
  # Pending rows with no job to carry them out, and no attempt in progress.
  scope :stale, lambda { |now = Time.current|
    pending.where("leased_until IS NULL OR leased_until < ?", now)
      .where("(enqueued_at IS NULL AND requested_at < :unqueued) OR updated_at < :lost",
        unqueued: now - UNQUEUED_AFTER, lost: now - LOST_AFTER)
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
  # sweep (or a repeat stop) queues it again. Returns the ids queued.
  def self.enqueue!(ids, now: Time.current, stale: false)
    scope = stale ? self.stale(now) : unqueued
    scope.where(id: ids).order(:id).pluck(:id, :job_id).filter_map do |id, owner|
      id if claim_and_enqueue(scope, id, owner, now)
    end
  end

  def self.claim_and_enqueue(scope, id, owner, now)
    job = RevokeEmployeeAppClerkJob.new(id)
    return false unless scope.where(id: id, job_id: owner).update_all(job_id: job.job_id, enqueued_at: now, updated_at: now) == 1
    return true if job.enqueue

    raise ActiveJob::EnqueueError, "not queued"
  rescue StandardError => error
    Rails.logger.error("[EmployeeAppClerkRevocation] could not queue revocation #{id}: #{error.class}")
    where(id: id, job_id: job&.job_id).update_all(job_id: owner, enqueued_at: nil) if job
    false
  end
  private_class_method :claim_and_enqueue

  # Starts an attempt for this job: counts it and takes the lease, only if
  # the row is still pending, this job owns it (or no job has claimed it
  # yet), and no other attempt holds the lease. Returns the row, or nil.
  def self.start_attempt!(id, job_id:, now: Time.current)
    started = pending.where(id: id).where("job_id IS NULL OR job_id = ?", job_id)
      .where("leased_until IS NULL OR leased_until < ?", now)
      .update_all([ "attempts = attempts + 1, leased_until = ?, updated_at = ?", now + ATTEMPT_LEASE, now ])
    find(id) if started == 1
  end

  # Records an outcome under the row lock, only while the row is still
  # pending and owned by this job. Yields the locked row; whatever the block
  # writes (the outcome and its audit) commits or rolls back together.
  # Returns the block's value, or nil when the row was no longer this job's.
  def finish!(job_id:)
    transaction do
      lock!
      yield self if pending? && owned_by?(job_id)
    end
  end

  def release_lease!
    self.class.where(id: id).update_all(leased_until: nil)
  end

  def owned_by?(other_job_id)
    job_id.nil? || job_id == other_job_id
  end

  def pending?
    confirmed_at.nil? && gave_up_at.nil? && follow_up_at.nil?
  end
end
