# frozen_string_literal: true

class CheckPrintGeneration < ApplicationRecord
  STATUSES = %w[queued processing ready failed].freeze
  PHASES = %w[queued validating rendering assembling uploading verifying ready failed].freeze
  ACTIVE_STATUSES = %w[queued processing].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :requested_by, class_name: "User"
  belongs_to :printer_profile
  belongs_to :check_print_run, optional: true

  validates :idempotency_key, :request_digest, presence: true
  validates :idempotency_key, uniqueness: { scope: %i[company_id requested_by_id] }
  validates :status, inclusion: { in: STATUSES }
  validates :phase, inclusion: { in: PHASES }
  validates :starting_slot, inclusion: { in: 1..4 }
  validates :printer_profile_lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :completed_items, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_items, numericality: { only_integer: true, greater_than: 0 }
  validate :progress_does_not_exceed_total
  validate :pay_period_belongs_to_company
  validate :result_is_ready_only

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def active?
    status.in?(ACTIVE_STATUSES)
  end

  def ready?
    status == "ready"
  end

  def failed?
    status == "failed"
  end

  def begin_processing!(job_id:)
    normalized_job_id = job_id.to_s.strip
    raise ArgumentError, "A queue job identifier is required" if normalized_job_id.blank?

    with_lock do
      resumable = status == "processing" && worker_job_id == normalized_job_id
      return false unless status == "queued" || resumable

      update!(
        status: "processing",
        phase: "validating",
        completed_items: 0,
        started_at: started_at || Time.current,
        worker_job_id: normalized_job_id
      )
      true
    end
  end

  def advance!(next_phase, completed_items: self.completed_items)
    raise ArgumentError, "Unsupported generation phase" unless PHASES.include?(next_phase.to_s)
    return if !active? || next_phase.to_s.in?(%w[queued ready failed])

    update_columns(
      phase: next_phase.to_s,
      completed_items: completed_items.to_i.clamp(0, total_items),
      updated_at: Time.current
    )
  end

  def complete_with!(run)
    update!(
      check_print_run: run,
      status: "ready",
      phase: "ready",
      completed_items: total_items,
      completed_at: Time.current,
      error_code: nil,
      error_message: nil,
      failed_at: nil
    )
  end

  def fail_safely!(code:, message:)
    update_columns(
      status: "failed",
      phase: "failed",
      error_code: code.to_s.first(80),
      error_message: message.to_s.first(500),
      failed_at: Time.current,
      updated_at: Time.current
    )
  end

  private

  def progress_does_not_exceed_total
    return if completed_items.to_i <= total_items.to_i

    errors.add(:completed_items, "cannot exceed the selected check count")
  end

  def pay_period_belongs_to_company
    return if pay_period.blank? || company_id.blank? || pay_period.company_id == company_id

    errors.add(:pay_period, "must belong to the same company")
  end

  def result_is_ready_only
    return if check_print_run_id.blank? || status == "ready"

    errors.add(:check_print_run, "can only be attached to a ready generation")
  end
end
