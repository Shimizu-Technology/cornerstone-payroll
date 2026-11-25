# frozen_string_literal: true

# A Clerk revocation the demo kill switch requested (M4-9d): a pending
# sign-up invitation, or every session of an employee-only demo login. The
# row is the durable request; RevokeEmployeeAppClerkJob retries it until
# Clerk confirms (confirmed_at), the retries run out (gave_up_at), or Clerk's
# answer needs a person to check it (follow_up_at; an invitation already
# accepted whose sign-in couldn't be found). Each outcome is audited
# separately from the request. While a row is still pending, a repeat stop
# finds it instead of queueing a duplicate, and queues its job again if none
# was queued; RetryEmployeeAppClerkRevocationsJob re-enqueues rows whose job
# never ran or was lost.
class EmployeeAppClerkRevocation < ApplicationRecord
  KINDS = %w[invitation sessions].freeze
  SOURCE_DEMO_STOP = "demo_stop"
  # A pending row never queued this long after its request, or untouched
  # this long (longer than the job's slowest retry wait), has no live job.
  UNQUEUED_AFTER = 5.minutes
  LOST_AFTER = 6.hours

  belongs_to :organization
  belongs_to :company
  belongs_to :user, optional: true
  belongs_to :requested_by, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :target, :source, :requested_at, presence: true

  scope :pending, -> { where(confirmed_at: nil, gave_up_at: nil, follow_up_at: nil) }
  # Pending rows with no job to carry them out.
  scope :stale, lambda { |now = Time.current|
    pending.where("(enqueued_at IS NULL AND requested_at < :unqueued) OR updated_at < :lost",
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

  # Queues the job for each pending row and records when. A failed enqueue
  # leaves enqueued_at unset, so the sweep (or a repeat stop) queues it again.
  # Returns the ids queued.
  def self.enqueue!(ids, now: Time.current)
    pending.where(id: ids).order(:id).pluck(:id).select do |id|
      RevokeEmployeeAppClerkJob.perform_later(id)
      where(id: id).update_all(enqueued_at: now, updated_at: now)
      true
    rescue StandardError => error
      Rails.logger.error("[EmployeeAppClerkRevocation] could not queue revocation #{id}: #{error.class}")
      false
    end
  end

  def pending?
    confirmed_at.nil? && gave_up_at.nil? && follow_up_at.nil?
  end
end
