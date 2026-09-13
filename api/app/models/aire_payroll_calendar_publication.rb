# frozen_string_literal: true

class AirePayrollCalendarPublication < ApplicationRecord
  DELIVERY_STATUSES = %w[pending failed delivered].freeze
  ENQUEUE_RESERVATION = 5.minutes
  BATCH_SIZE = 100

  belongs_to :aire_payroll_calendar_period, inverse_of: :publications
  belongs_to :created_by, class_name: "User", optional: true
  has_many :payroll_events,
           class_name: "AirePayrollEvent",
           dependent: :restrict_with_error,
           inverse_of: :aire_payroll_calendar_publication

  validates :schedule_version, numericality: { only_integer: true, greater_than: 0 },
                               uniqueness: { scope: :aire_payroll_calendar_period_id }
  validates :publication_id, presence: true, uniqueness: true,
            format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i }
  validates :payload_checksum, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :delivery_status, inclusion: { in: DELIVERY_STATUSES }
  validates :delivery_attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :immutable_evidence, on: :update
  validate :delivered_record_is_final, on: :update
  before_destroy :prevent_destroy

  scope :due_for_delivery, lambda { |now = Time.current|
    where(delivery_status: %w[pending failed])
      .where.not(next_delivery_attempt_at: nil)
      .where(next_delivery_attempt_at: ..now)
      .where("delivery_enqueued_until IS NULL OR delivery_enqueued_until <= ?", now)
  }

  def self.dispatch_due!(now: Time.current, enqueue: nil)
    due_for_delivery(now).order(:created_at, :id).limit(BATCH_SIZE).pluck(:id).filter_map do |id|
      begin
        id if dispatch_one!(id, now: now, enqueue: enqueue)
      rescue StandardError => e
        Rails.logger.error("AIRE calendar publication #{id} could not be queued: #{e.class}: #{e.message}")
        nil
      end
    end
  end

  def self.dispatch_one!(id, now: Time.current, enqueue: nil)
    enqueue ||= ->(publication_id) { AirePayrollCalendarDeliveryJob.perform_later(publication_id) }
    reservation = reserve_for_enqueue(id, now)
    return false unless reservation

    begin
      enqueue.call(id)
      true
    rescue StandardError
      where(id: id, delivery_enqueued_until: reservation).update_all(
        delivery_enqueued_until: nil,
        updated_at: Time.current
      )
      raise
    end
  end

  def self.reserve_for_enqueue(id, now)
    transaction do
      publication = lock.find(id)
      return if publication.delivered?
      return if publication.next_delivery_attempt_at.nil?
      return if publication.next_delivery_attempt_at&.>(now)
      return if publication.delivery_enqueued_until&.>(now)

      reservation = now + ENQUEUE_RESERVATION
      publication.update!(delivery_enqueued_until: reservation)
      reservation
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def delivered?
    delivery_status == "delivered"
  end

  def cutoff_at
    Time.iso8601(payload.fetch("cutoff_at"))
  end

  private

  def immutable_evidence
    changed = changes_to_save.keys & %w[
      aire_payroll_calendar_period_id schedule_version publication_id payload payload_checksum created_by_id created_at
    ]
    errors.add(:base, "AIRE calendar publication evidence is immutable") if changed.any?
  end

  def delivered_record_is_final
    return unless delivery_status_in_database == "delivered"
    return unless changes_to_save.except("updated_at").any?

    errors.add(:base, "Delivered AIRE calendar publication evidence is final")
  end

  def prevent_destroy
    errors.add(:base, "AIRE calendar publication evidence is append-only")
    throw(:abort)
  end
end
