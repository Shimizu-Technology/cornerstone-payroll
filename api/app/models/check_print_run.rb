# frozen_string_literal: true

class CheckPrintRun < ApplicationRecord
  STATUSES = %w[generated confirmed].freeze
  CONFIRMATION_ATTRIBUTES = %w[status confirmed_at confirmed_by_id updated_at].freeze

  belongs_to :company
  belongs_to :pay_period
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :check_stock_type, :storage_key, :filename, :sha256, presence: true
  validates :storage_key, uniqueness: true
  validates :starting_slot, inclusion: { in: 1..4 }
  validates :selected_count, numericality: { only_integer: true, greater_than: 0 }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
  validate :manifest_matches_selected_count
  validate :pay_period_belongs_to_company

  before_update :prevent_artifact_mutation
  before_destroy :prevent_destroy

  def confirmed?
    status == "confirmed"
  end

  private

  def manifest_matches_selected_count
    return if manifest.is_a?(Array) && manifest.size == selected_count.to_i

    errors.add(:manifest, "must contain one entry per selected check")
  end

  def pay_period_belongs_to_company
    return if pay_period.blank? || company_id.blank? || pay_period.company_id == company_id

    errors.add(:pay_period, "must belong to the same company")
  end

  def prevent_artifact_mutation
    disallowed = changes_to_save.keys - CONFIRMATION_ATTRIBUTES
    return if disallowed.empty?

    errors.add(:base, "Generated check print artifacts are immutable")
    throw :abort
  end

  def prevent_destroy
    errors.add(:base, "Check print history is immutable")
    throw :abort
  end
end
