# frozen_string_literal: true

class HistoricalClientBootstrap < ApplicationRecord
  STATUSES = %w[previewed applied].freeze

  belongs_to :company
  belongs_to :historical_import_batch
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :applied_by, class_name: "User", optional: true

  validates :historical_import_batch_id, uniqueness: true
  validates :plan_digest, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :company_matches_batch

  before_update :prevent_applied_update
  before_destroy :prevent_destroy

  def previewed?
    status == "previewed"
  end

  def applied?
    status == "applied"
  end

  def ready_to_apply?
    previewed? && Array(validation_errors).empty?
  end

  private

  def company_matches_batch
    return if historical_import_batch.blank? || historical_import_batch.company_id == company_id

    errors.add(:company_id, "must match the historical import batch")
  end

  def prevent_applied_update
    persisted_status = self.class.lock.where(id: id).pick(:status)
    return unless persisted_status == "applied"

    errors.add(:base, "Applied client bootstraps cannot be changed")
    throw(:abort)
  end

  def prevent_destroy
    errors.add(:base, "Client bootstrap evidence cannot be deleted")
    throw(:abort)
  end
end
