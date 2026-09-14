# frozen_string_literal: true

class OperationalQueueProbe < ApplicationRecord
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  validates :probe_id, presence: true, uniqueness: true, format: { with: UUID_PATTERN }
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :effect_count, numericality: { only_integer: true, in: 0..1 }
  validates :expires_at, presence: true
  validate :completion_is_consistent

  scope :expired, -> { where(expires_at: ..Time.current) }

  def passed?
    attempt_count.positive? && effect_count == 1 && completed_at.present?
  end

  private

  def completion_is_consistent
    return if (effect_count.zero? && completed_at.nil?) || (effect_count == 1 && completed_at.present?)

    errors.add(:completed_at, "must be present exactly when the probe effect is recorded")
  end
end
