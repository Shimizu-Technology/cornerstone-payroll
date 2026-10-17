# frozen_string_literal: true

class TimeTrackingManualAllocation < ApplicationRecord
  STATUSES = %w[pending_commit committed issued voided].freeze

  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :pay_period
  belongs_to :payroll_item
  belongs_to :employee
  belongs_to :created_by, class_name: "User"
  belongs_to :classification_reconciliation, class_name: "TimeTrackingClassificationReconciliation", optional: true,
             inverse_of: :time_tracking_manual_allocations

  validates :source_user_uuid, :source_time_entry_id, :source_time_entry_version,
            :original_work_date, :reconciliation_note, :commit_command_id,
            :issue_command_id, :void_command_id, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :regular_hours, :overtime_hours, numericality: { greater_than_or_equal_to: 0 }
  validate :hours_are_positive
  validate :ownership_reconciles
  validate :classification_reconciliation_ownership
  validate :preserve_payment_resolution_evidence, on: :update

  before_validation :assign_command_ids, on: :create

  scope :resolution_history_for_period, ->(period) {
    where("pay_period_id = :id OR payment_resolution_intent->>'review_pay_period_id' = :reference OR original_work_date BETWEEN :start AND :finish",
      id: period.id, reference: period.id.to_s, start: period.start_date, finish: period.end_date)
  }
  scope :pending_payment_resolution, -> { where.not(payment_resolution_intent: {}).where(payment_resolution_receipt: {}) }

  def payment_resolution_pending?
    payment_resolution_intent.present? && payment_resolution_receipt.blank?
  end

  def total_hours
    regular_hours.to_d + overtime_hours.to_d
  end

  private

  def preserve_payment_resolution_evidence
    return if payment_resolution_intent_in_database.blank?

    frozen_fields = %w[payment_resolution_intent source_payment_attestation_id time_tracking_source_id company_id
      pay_period_id payroll_item_id employee_id created_by_id source_user_uuid source_time_entry_id
      source_time_entry_version original_work_date regular_hours overtime_hours reconciliation_note]
    if (changes_to_save.keys & frozen_fields).any? ||
        (payment_resolution_receipt_in_database.present? && will_save_change_to_payment_resolution_receipt?)
      errors.add(:base, "The original reported-payment command, reservation and receipt are immutable")
    end
  end

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

  def classification_reconciliation_ownership
    return unless classification_reconciliation
    return if classification_reconciliation.company_id == company_id &&
              classification_reconciliation.time_tracking_source_id == time_tracking_source_id &&
              classification_reconciliation.pay_period_id == pay_period_id &&
              classification_reconciliation.payroll_item_id == payroll_item_id &&
              classification_reconciliation.employee_id == employee_id &&
              classification_reconciliation.source_user_uuid == source_user_uuid

    errors.add(:base, "Historical classification exception must belong to the same employee and check")
  end
end
