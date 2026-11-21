# frozen_string_literal: true

# One pull of Cornerstone Tax's Work Hours feed for a date range. A succeeded
# import's rows replace every earlier row in its range (see
# TaxWorkHours::Importer); a failed import changes nothing.
class WorkHourImport < ApplicationRecord
  STATUSES = %w[queued running succeeded failed].freeze
  TRIGGERS = %w[manual scheduled].freeze
  ACTIVE_STATUSES = %w[queued running].freeze
  # A queued or running import older than this is treated as abandoned.
  STALE_AFTER = 15.minutes
  MAX_RANGE_MONTHS = 24

  belongs_to :organization
  belongs_to :requested_by, class_name: "User", optional: true
  has_many :work_hour_rows, dependent: :delete_all

  validates :status, inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }
  validates :range_start, :range_end, presence: true
  validate :range_is_ordered_and_bounded

  scope :succeeded, -> { where(status: "succeeded") }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :in_progress, -> { where(status: ACTIVE_STATUSES).where("created_at > ?", STALE_AFTER.ago) }

  def in_progress?
    status.in?(ACTIVE_STATUSES) && created_at.present? && created_at > STALE_AFTER.ago
  end

  def as_status_json
    {
      id: id,
      status: in_progress? || status.in?(%w[succeeded failed]) ? status : "failed",
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
      error_code: status.in?(ACTIVE_STATUSES) && !in_progress? ? "interrupted" : error_code,
      error_message: status.in?(ACTIVE_STATUSES) && !in_progress? ? "This refresh stopped before it finished. Try again." : error_message
    }
  end

  private

  def range_is_ordered_and_bounded
    return if range_start.blank? || range_end.blank?

    errors.add(:range_end, "must be on or after the start") if range_end < range_start
    errors.add(:range_end, "can be at most #{MAX_RANGE_MONTHS} months after the start") if range_end > (range_start >> MAX_RANGE_MONTHS)
  end
end
