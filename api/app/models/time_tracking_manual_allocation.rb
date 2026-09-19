# frozen_string_literal: true

class TimeTrackingManualAllocation < ApplicationRecord
  STATUSES = %w[pending_commit committed issued voided].freeze

  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :pay_period
  belongs_to :payroll_item
  belongs_to :employee
  belongs_to :created_by, class_name: "User"

  validates :source_user_uuid, :source_time_entry_id, :source_time_entry_version,
            :original_work_date, :reconciliation_note, :commit_command_id,
            :issue_command_id, :void_command_id, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :regular_hours, :overtime_hours, numericality: { greater_than_or_equal_to: 0 }
  validate :hours_are_positive
  validate :ownership_reconciles

  before_validation :assign_command_ids, on: :create

  def total_hours
    regular_hours.to_d + overtime_hours.to_d
  end

  private

  def assign_command_ids
    self.commit_command_id ||= SecureRandom.uuid
    self.issue_command_id ||= SecureRandom.uuid
    self.void_command_id ||= SecureRandom.uuid
  end

  def hours_are_positive
    return if regular_hours.blank? || overtime_hours.blank? || total_hours.positive?

    errors.add(:base, "Select at least some AIRE hours")
  end

  def ownership_reconciles
    return if [ company, time_tracking_source, pay_period, payroll_item, employee ].any?(&:nil?)
    return if time_tracking_source.company_id == company_id &&
      pay_period.company_id == company_id &&
      payroll_item.pay_period_id == pay_period_id &&
      payroll_item.employee_id == employee_id &&
      employee.company_id == company_id

    errors.add(:base, "AIRE manual allocation must belong to the same company, period, and employee")
  end
end
