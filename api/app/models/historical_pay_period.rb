# frozen_string_literal: true

class HistoricalPayPeriod < ApplicationRecord
  PERIOD_TYPES = %w[regular opening_summary].freeze

  belongs_to :historical_import_batch
  belongs_to :company
  has_many :historical_paychecks, dependent: :restrict_with_error

  validates :external_key, :source_label, :start_date, :end_date, :pay_date, presence: true
  validates :external_key, uniqueness: { scope: :historical_import_batch_id }
  validates :period_type, inclusion: { in: PERIOD_TYPES }
  validates :paycheck_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :date_order
  validate :company_consistency

  before_update :prevent_snapshot_mutation
  before_destroy :prevent_non_preview_destroy

  scope :chronological, -> { order(:pay_date, :start_date, :id) }
  scope :reverse_chronological, -> { order(pay_date: :desc, start_date: :desc, id: :desc) }

  private

  def date_order
    return if start_date.blank? || end_date.blank? || pay_date.blank?

    errors.add(:end_date, "must be on or after the start date") if end_date < start_date
    errors.add(:pay_date, "must be on or after the period end date") if pay_date < end_date
  end

  def company_consistency
    return if historical_import_batch.blank? || historical_import_batch.company_id == company_id

    errors.add(:company_id, "must match the historical import batch")
  end

  def prevent_snapshot_mutation
    errors.add(:base, "Historical pay period snapshots are immutable")
    throw(:abort)
  end

  def prevent_non_preview_destroy
    return if historical_import_batch.previewed? || historical_import_batch.status == "failed"

    errors.add(:base, "Applied historical pay periods cannot be deleted")
    throw(:abort)
  end
end
