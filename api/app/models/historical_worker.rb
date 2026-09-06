# frozen_string_literal: true

class HistoricalWorker < ApplicationRecord
  SOURCE_STATUSES = %w[active inactive unknown].freeze
  MAPPING_STATUSES = %w[needs_review exact_match manual_match archive_only].freeze

  belongs_to :historical_import_batch
  belongs_to :company
  belongs_to :employee, optional: true
  has_many :historical_paychecks, dependent: :restrict_with_error

  encrypts :private_snapshot

  validates :external_key, :source_name, :normalized_name, presence: true
  validates :external_key, uniqueness: { scope: :historical_import_batch_id }
  validates :source_status, inclusion: { in: SOURCE_STATUSES }
  validates :mapping_status, inclusion: { in: MAPPING_STATUSES }
  validates :employee, presence: true, if: -> { mapping_status.in?(%w[exact_match manual_match]) }
  validates :employee, absence: true, if: -> { mapping_status.in?(%w[needs_review archive_only]) }
  validate :company_consistency

  before_update :prevent_locked_batch_update
  before_destroy :prevent_non_preview_destroy

  def private_snapshot_data
    return {} if private_snapshot.blank?

    JSON.parse(private_snapshot)
  rescue JSON::ParserError
    {}
  end

  def reviewed?
    mapping_status != "needs_review"
  end

  private

  def company_consistency
    return if historical_import_batch.blank? || historical_import_batch.company_id == company_id

    errors.add(:company_id, "must match the historical import batch")
  end

  def prevent_locked_batch_update
    return unless historical_import_batch.locked?

    errors.add(:base, "Locked historical workers cannot be changed")
    throw(:abort)
  end

  def prevent_non_preview_destroy
    return if historical_import_batch.previewed? || historical_import_batch.status == "failed"

    errors.add(:base, "Applied historical workers cannot be deleted")
    throw(:abort)
  end
end
