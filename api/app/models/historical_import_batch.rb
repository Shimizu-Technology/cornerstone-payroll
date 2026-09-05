# frozen_string_literal: true

class HistoricalImportBatch < ApplicationRecord
  STATUSES = %w[previewed applied locked failed].freeze
  SOURCE_SYSTEMS = %w[quickbooks_online].freeze

  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :applied_by, class_name: "User", optional: true
  belongs_to :locked_by, class_name: "User", optional: true

  has_many :historical_paychecks, dependent: :destroy
  has_many :historical_pay_periods, dependent: :destroy
  has_many :historical_workers, dependent: :destroy

  validates :source_system, inclusion: { in: SOURCE_SYSTEMS }
  validates :source_label, :bundle_digest, :importer_version, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :bundle_digest, uniqueness: { scope: %i[company_id source_system] }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :visible_history, -> { where(status: %w[applied locked]) }

  before_destroy :prevent_visible_history_destroy, prepend: true

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

  private

  def prevent_visible_history_destroy
    return unless applied? || locked?

    errors.add(:base, "Applied historical imports cannot be deleted")
    throw(:abort)
  end
end
