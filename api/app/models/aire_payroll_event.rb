# frozen_string_literal: true

class AirePayrollEvent < ApplicationRecord
  VERIFICATION_STATUSES = %w[pending failed rejected verified].freeze
  EVENT_TYPE = "payroll_batch.finalized"
  ENQUEUE_RESERVATION = 5.minutes
  BATCH_SIZE = 100

  belongs_to :aire_payroll_calendar_period, inverse_of: :payroll_events
  belongs_to :aire_payroll_calendar_publication, inverse_of: :payroll_events
  belongs_to :time_tracking_source

  validates :event_id, presence: true, uniqueness: true,
            format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i }
  validates :event_type, inclusion: { in: [ EVENT_TYPE ] }
  validates :occurred_at, :payroll_batch_id, presence: true
  validates :payroll_batch_id, uniqueness: { scope: :time_tracking_source_id }
  validates :payload_checksum, :payroll_batch_checksum, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
  validates :verification_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :publication_belongs_to_period
  validate :immutable_evidence, on: :update
  validate :verified_record_is_final, on: :update
  before_destroy :prevent_destroy

  scope :verified, -> { where(verification_status: "verified") }
  scope :due_for_verification, lambda { |now = Time.current|
    where(verification_status: %w[pending failed])
      .where("next_verification_attempt_at IS NULL OR next_verification_attempt_at <= ?", now)
      .where("verification_enqueued_until IS NULL OR verification_enqueued_until <= ?", now)
  }

  def self.dispatch_due!(now: Time.current, enqueue: nil)
    due_for_verification(now).order(:occurred_at, :id).limit(BATCH_SIZE).pluck(:id).filter_map do |id|
      begin
        id if dispatch_one!(id, now: now, enqueue: enqueue)
      rescue StandardError => e
        Rails.logger.error("AIRE payroll event #{id} could not be queued: #{e.class}: #{e.message}")
        nil
      end
    end
  end

  def self.dispatch_one!(id, now: Time.current, enqueue: nil)
    enqueue ||= ->(event_id) { AirePayrollEventVerificationJob.perform_later(event_id) }
    reservation = reserve_for_enqueue(id, now)
    return false unless reservation

    begin
      enqueue.call(id)
      true
    rescue StandardError
      where(id: id, verification_enqueued_until: reservation).update_all(
        verification_enqueued_until: nil,
        updated_at: Time.current
      )
      raise
    end
  end

  def self.reserve_for_enqueue(id, now)
    transaction do
      event = lock.find(id)
      return unless event.verification_status.in?(%w[pending failed])
      return if event.next_verification_attempt_at&.>(now)
      return if event.verification_enqueued_until&.>(now)

      reservation = now + ENQUEUE_RESERVATION
      event.update!(verification_enqueued_until: reservation)
      reservation
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def verified?
    verification_status == "verified"
  end

  private

  def publication_belongs_to_period
    return unless aire_payroll_calendar_publication && aire_payroll_calendar_period
    publication_matches = aire_payroll_calendar_publication.aire_payroll_calendar_period_id == aire_payroll_calendar_period_id
    source_matches = time_tracking_source_id == aire_payroll_calendar_period.time_tracking_source_id
    return if publication_matches && source_matches

    errors.add(:base, "AIRE event publication and source must belong to the calendar period")
  end

  def immutable_evidence
    changed = changes_to_save.keys & %w[
      aire_payroll_calendar_period_id aire_payroll_calendar_publication_id time_tracking_source_id event_id event_type occurred_at payload
      payload_checksum payroll_batch_id payroll_batch_checksum created_at
    ]
    errors.add(:base, "AIRE payroll event evidence is immutable") if changed.any?
  end

  def verified_record_is_final
    return unless verification_status_in_database == "verified"
    return unless changes_to_save.except("updated_at").any?

    errors.add(:base, "Verified AIRE payroll event evidence is final")
  end

  def prevent_destroy
    errors.add(:base, "AIRE payroll event evidence is append-only")
    throw(:abort)
  end
end
