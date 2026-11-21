# frozen_string_literal: true

# One pull of Cornerstone Tax's Work Hours feed for a date range.
#
# Lifecycle (TaxWorkHours::Importer):
# - reserve!: manual and nightly refreshes both create imports here, under the
#   organization row lock. A partial unique index allows at most one queued or
#   running import per organization. An abandoned one (lease expired) is marked
#   failed first, so a stuck import never blocks refreshes for long.
# - claim!: a worker atomically takes a queued import, or a running one whose
#   lease has expired (its worker died), and gets a fresh claim_token.
# - renew_lease!: the worker extends its lease between months; it fails once
#   another worker has taken over.
# - commit: rows are replaced only while the worker still holds claim_token
#   and its lease has not expired (checked with the import row locked), so a
#   superseded or late worker can never overwrite newer hours.
#
# Lock order, everywhere: the organization row, then the import row. reserve!
# and the importer's save both follow it, so they can't deadlock.
class WorkHourImport < ApplicationRecord
  STATUSES = %w[queued running succeeded failed].freeze
  TRIGGERS = %w[manual scheduled].freeze
  ACTIVE_STATUSES = %w[queued running].freeze
  # How long a queued import may wait for a worker, and how long a running
  # import may go without renewing its lease, before it counts as abandoned.
  QUEUED_LEASE = 15.minutes
  RUNNING_LEASE = 5.minutes
  MAX_RANGE_MONTHS = 24
  INTERRUPTED_MESSAGE = "This refresh stopped before it finished. Nothing was changed. Try again."

  class Busy < StandardError; end

  belongs_to :organization
  belongs_to :requested_by, class_name: "User", optional: true
  has_many :work_hour_rows, dependent: :delete_all

  validates :status, inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }
  validates :range_start, :range_end, presence: true
  validate :range_is_ordered_and_bounded

  scope :succeeded, -> { where(status: "succeeded") }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :active, -> { where(status: ACTIVE_STATUSES) }

  # Creates the organization's one active import, or raises Busy while a live
  # one exists. Callers enqueue or run it only after this returns.
  def self.reserve!(organization:, range_start:, range_end:, trigger:, requested_by: nil, now: Time.current)
    transaction do
      organization.lock!
      current = active.where(organization_id: organization.id).lock.first
      if current
        raise Busy, "A refresh is already running. Wait for it to finish." if current.lease_expires_at && current.lease_expires_at > now

        current.update!(status: "failed", finished_at: now, claim_token: nil, error_code: "interrupted", error_message: INTERRUPTED_MESSAGE)
      end
      create!(organization: organization, requested_by: requested_by, trigger: trigger, status: "queued",
              range_start: range_start, range_end: range_end, lease_expires_at: now + QUEUED_LEASE)
    end
  rescue ActiveRecord::RecordNotUnique
    raise Busy, "A refresh is already running. Wait for it to finish."
  end

  # Takes this import for one worker. Returns the claim token, or nil when it
  # is finished, superseded, or still held by a live worker.
  def claim!(now: Time.current)
    token = SecureRandom.uuid
    claimed = self.class.where(id: id)
                  .where("status = 'queued' OR (status = 'running' AND (lease_expires_at IS NULL OR lease_expires_at <= ?))", now)
                  .update_all(status: "running", claim_token: token, started_at: now, lease_expires_at: now + RUNNING_LEASE,
                              error_code: nil, error_message: nil, updated_at: now)
    return nil unless claimed == 1

    reload
    token
  end

  # Extends a live lease. An expired lease can't be renewed, even by the
  # worker that held it: once it ends, another worker may have taken over.
  # The expiry is checked in the same UPDATE statement.
  def renew_lease!(token, now: Time.current)
    self.class.where(id: id, status: "running", claim_token: token).where("lease_expires_at > ?", now)
        .update_all(lease_expires_at: now + RUNNING_LEASE, updated_at: now) == 1
  end

  # Ends an import whose worker outlived its lease, unless another worker has
  # already taken it over (then that worker owns the outcome).
  def expire_lease!(token, now: Time.current)
    self.class.where(id: id, status: "running", claim_token: token)
        .update_all(status: "failed", finished_at: now, claim_token: nil, lease_expires_at: nil, error_code: "lease_expired",
                    error_message: "This refresh took too long and was stopped. Nothing was changed. Try again.", updated_at: now)
  end

  # Seconds until a running import's lease ends; nil once it can be claimed.
  def lease_remaining(now: Time.current)
    return nil unless status == "running" && lease_expires_at && lease_expires_at > now

    (lease_expires_at - now).ceil
  end

  def abandoned?(now: Time.current)
    status.in?(ACTIVE_STATUSES) && (lease_expires_at.nil? || lease_expires_at <= now)
  end

  def as_status_json
    stuck = abandoned?
    {
      id: id,
      status: stuck ? "failed" : status,
      trigger: trigger,
      range_start: range_start.iso8601,
      range_end: range_end.iso8601,
      requested_by: requested_by&.name.presence || requested_by&.email,
      created_at: created_at&.iso8601,
      started_at: started_at&.iso8601,
      finished_at: finished_at&.iso8601,
      row_count: row_count,
      total_hours: total_hours.to_d.round(2).to_s("F"),
      pending_entries: pending_entries,
      denied_entries: denied_entries,
      open_clock_entries: open_clock_entries,
      error_code: stuck ? "interrupted" : error_code,
      error_message: stuck ? INTERRUPTED_MESSAGE : error_message
    }
  end

  private

  def range_is_ordered_and_bounded
    return if range_start.blank? || range_end.blank?

    errors.add(:range_end, "must be on or after the start") if range_end < range_start
    errors.add(:range_end, "can be at most #{MAX_RANGE_MONTHS} months after the start") if range_end > (range_start >> MAX_RANGE_MONTHS)
  end
end
