# frozen_string_literal: true

class HistoricalImportSourceFile < ApplicationRecord
  VERIFICATION_STATUSES = %w[verified failed].freeze
  IMMUTABLE_FIELDS = %w[
    historical_import_batch_id company_id uploaded_by_id original_filename content_type
    byte_size sha256 storage_key report_type position
  ].freeze

  belongs_to :historical_import_batch
  belongs_to :company
  belongs_to :uploaded_by, class_name: "User", optional: true

  validates :original_filename, :content_type, :sha256, :storage_key, :report_type, presence: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
  validates :storage_key, uniqueness: true
  validates :position, uniqueness: { scope: :historical_import_batch_id }
  validate :company_matches_batch
  validate :source_metadata_immutable, on: :update

  before_destroy :prevent_destroy, prepend: true

  scope :in_manifest_order, -> { order(:position, :id) }

  def verified?
    verification_status == "verified"
  end

  private

  def company_matches_batch
    return if historical_import_batch.blank? || historical_import_batch.company_id == company_id

    errors.add(:company_id, "must match the historical import batch")
  end

  def source_metadata_immutable
    changed = changes_to_save.keys & IMMUTABLE_FIELDS
    return if changed.empty?

    errors.add(:base, "Historical source-file evidence cannot be changed")
  end

  def prevent_destroy
    errors.add(:base, "Historical source files cannot be deleted")
    throw(:abort)
  end
end
