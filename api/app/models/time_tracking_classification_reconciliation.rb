# frozen_string_literal: true

class TimeTrackingClassificationReconciliation < ApplicationRecord
  STATUSES = %w[pending complete].freeze

  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :pay_period
  belongs_to :payroll_item
  belongs_to :employee
  belongs_to :created_by, class_name: "User"
  has_many :time_tracking_manual_allocations, foreign_key: :classification_reconciliation_id,
             dependent: :restrict_with_error, inverse_of: :classification_reconciliation

  validates :source_user_uuid, :check_number, :payment_effective_on, :note, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source_regular_hours, :source_overtime_hours, :payroll_regular_hours,
            :payroll_overtime_hours, numericality: { greater_than_or_equal_to: 0 }
  validate :totals_match_and_split_differs
  validate :ownership_reconciles
  validate :preserve_original_evidence, on: :update

  def source_total_hours
    source_regular_hours.to_d + source_overtime_hours.to_d
  end

  private

  def preserve_original_evidence
    changed_evidence = changes_to_save.keys - %w[status updated_at]
    errors.add(:base, "Historical check and AIRE evidence cannot be edited") if changed_evidence.any?
    return unless will_save_change_to_status?
    return if status_in_database == "pending" && status == "complete"

    errors.add(:status, "can only move from pending to complete")
  end

  def totals_match_and_split_differs
    return if [ source_regular_hours, source_overtime_hours, payroll_regular_hours, payroll_overtime_hours ].any?(&:nil?)

    unless source_total_hours == payroll_regular_hours.to_d + payroll_overtime_hours.to_d
      errors.add(:base, "AIRE and issued-check total hours must match")
    end
    if source_regular_hours.to_d == payroll_regular_hours.to_d && source_overtime_hours.to_d == payroll_overtime_hours.to_d
      errors.add(:base, "Use ordinary exact-entry reconciliation when the regular and overtime splits match")
    end
  end

  def ownership_reconciles
    return if [ company, time_tracking_source, pay_period, payroll_item, employee ].any?(&:nil?)
    return if time_tracking_source.company_id == company_id && pay_period.company_id == company_id &&
              payroll_item.pay_period_id == pay_period_id && payroll_item.employee_id == employee_id &&
              employee.company_id == company_id

    errors.add(:base, "Historical classification reconciliation ownership must match")
  end
end
