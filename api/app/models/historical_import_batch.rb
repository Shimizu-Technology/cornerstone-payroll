# frozen_string_literal: true

class HistoricalImportBatch < ApplicationRecord
  STATUSES = %w[previewed applied locked failed].freeze
  SOURCE_SYSTEMS = %w[quickbooks_online].freeze

  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :applied_by, class_name: "User", optional: true
  belongs_to :locked_by, class_name: "User", optional: true

  has_many :historical_paychecks, dependent: :restrict_with_error
  has_many :historical_pay_periods, dependent: :restrict_with_error
  has_many :historical_workers, dependent: :restrict_with_error

  validates :source_system, inclusion: { in: SOURCE_SYSTEMS }
  validates :source_label, :bundle_digest, :importer_version, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :bundle_digest, uniqueness: { scope: %i[company_id source_system] }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :visible_history, -> { where(status: %w[applied locked]) }

  before_destroy :prevent_destroy, prepend: true
  before_update :prevent_locked_batch_update

  def previewed?
    status == "previewed"
  end

  def applied?
    status == "applied"
  end

  def locked?
    status == "locked"
  end

  def blocking_errors?
    Array(validation_errors).any?
  end

  def unresolved_worker_count
    historical_workers.where(mapping_status: "needs_review").count
  end

  private

  def prevent_locked_batch_update
    persisted_status = self.class.lock.where(id: id).pick(:status)
    return unless persisted_status == "locked"

    errors.add(:base, "Locked historical imports cannot be changed")
    throw(:abort)
  end

  def prevent_destroy
    errors.add(:base, "Historical imports cannot be deleted; retain the source and review record")
    throw(:abort)
  end
end
