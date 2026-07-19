# frozen_string_literal: true

class GeneralTransmittalArtifact < ApplicationRecord
  belongs_to :general_transmittal, inverse_of: :artifacts
  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true

  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :storage_key, :filename, :content_type, :sha256, :template_version, presence: true
  validates :storage_key, uniqueness: true
  validates :version_number, uniqueness: { scope: :general_transmittal_id }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :sha256, length: { is: 64 }
  validate :company_matches_transmittal

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :newest_first, -> { order(version_number: :desc) }

  def readonly?
    persisted?
  end

  private

  def company_matches_transmittal
    return if company_id.blank? || general_transmittal.blank?
    return if company_id == general_transmittal.company_id

    errors.add(:company_id, "must match the transmittal company")
  end

  def prevent_mutation
    errors.add(:base, "Generated transmittal versions are immutable")
    throw :abort
  end
end
