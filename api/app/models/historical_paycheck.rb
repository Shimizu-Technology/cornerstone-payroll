# frozen_string_literal: true

class HistoricalPaycheck < ApplicationRecord
  RECONCILIATION_STATUSES = %w[matched opening_summary unmatched].freeze

  belongs_to :historical_import_batch
  belongs_to :historical_pay_period
  belongs_to :historical_worker
  belongs_to :company
  belongs_to :employee, optional: true

  validates :external_key, :source_employee_name, :pay_date, :period_start, :period_end, presence: true
  validates :external_key, uniqueness: { scope: :historical_import_batch_id }
  validates :source_row_number, numericality: { only_integer: true, greater_than: 0 }
  validates :reconciliation_status, inclusion: { in: RECONCILIATION_STATUSES }
  validate :date_order
  validate :association_consistency

  before_update :prevent_snapshot_mutation
  before_destroy :prevent_non_preview_destroy

  scope :chronological, -> { order(:pay_date, :source_employee_name, :id) }
  scope :reverse_chronological, -> { order(pay_date: :desc, source_employee_name: :asc, id: :desc) }

  private

  def date_order
    return if period_start.blank? || period_end.blank? || pay_date.blank?

    errors.add(:period_end, "must be on or after the period start") if period_end < period_start
    errors.add(:pay_date, "must be on or after the period end") if pay_date < period_end
  end

  def association_consistency
    return if historical_import_batch.blank? || historical_pay_period.blank? || historical_worker.blank?

    ids = [ historical_import_batch.company_id, historical_pay_period.company_id, historical_worker.company_id, company_id ].uniq
    errors.add(:company_id, "must match every historical import record") if ids.many?
    errors.add(:historical_pay_period_id, "must belong to the same batch") if historical_pay_period.historical_import_batch_id != historical_import_batch_id
    errors.add(:historical_worker_id, "must belong to the same batch") if historical_worker.historical_import_batch_id != historical_import_batch_id
  end

  def prevent_snapshot_mutation
    # Employee linkage is changed only by MappingService's locked, preview-only
    # bulk write. Ordinary model updates remain fully immutable.
    errors.add(:base, "Historical paycheck snapshots are immutable")
    throw(:abort)
  end

  def prevent_non_preview_destroy
    return if historical_import_batch.previewed? || historical_import_batch.status == "failed"

    errors.add(:base, "Applied historical paychecks cannot be deleted")
    throw(:abort)
  end
end
