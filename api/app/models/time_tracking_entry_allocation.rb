# frozen_string_literal: true

class TimeTrackingEntryAllocation < ApplicationRecord
  SOURCE_KINDS = %w[current carryover correction].freeze

  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :time_tracking_import
  belongs_to :pay_period
  belongs_to :payroll_item
  belongs_to :employee

  validates :source_user_id, :source_time_entry_id, :line_key, :source_kind, :original_work_date, presence: true
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :line_key, uniqueness: { scope: [ :time_tracking_import_id, :source_time_entry_id ] }
  validates :source_user_uuid, format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i }, allow_nil: true
  validates :total_hours, :regular_hours, :overtime_hours, numericality: true
  validate :hours_reconcile
  validate :ownership_reconciles

  def readonly?
    persisted?
  end

  private

  def hours_reconcile
    return if total_hours.blank? || regular_hours.blank? || overtime_hours.blank?
    return if total_hours.to_d == regular_hours.to_d + overtime_hours.to_d

    errors.add(:total_hours, "must equal regular plus overtime hours")
  end

  def ownership_reconciles
    return if [ company, time_tracking_source, time_tracking_import, pay_period, payroll_item, employee ].any?(&:nil?)
    return if time_tracking_source.company_id == company_id &&
      time_tracking_import.time_tracking_source_id == time_tracking_source_id &&
      time_tracking_import.pay_period_id == pay_period_id &&
      pay_period.company_id == company_id &&
      payroll_item.pay_period_id == pay_period_id &&
      payroll_item.employee_id == employee_id &&
      employee.company_id == company_id

    errors.add(:base, "Time tracking allocation ownership must reconcile")
  end
end
