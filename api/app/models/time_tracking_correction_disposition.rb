# frozen_string_literal: true

class TimeTrackingCorrectionDisposition < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :time_tracking_import
  belongs_to :original_allocation, class_name: "TimeTrackingEntryAllocation"
  belongs_to :corrective_payroll_item, class_name: "PayrollItem"
  belongs_to :created_by, class_name: "User"
  has_one :time_tracking_correction_receipt, dependent: :restrict_with_error

  validates :source_instance_id, :batch_id, :batch_checksum, :source_user_id, :source_user_uuid,
    :source_time_entry_id, :line_key, :line_snapshot, :proof_digest, :reason, presence: true
  validates :source_kind, inclusion: { in: [ "correction" ] }
  validates :total_hours, :regular_hours, :overtime_hours, numericality: true
  validates :batch_checksum, :proof_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :source_instance_id, :source_user_uuid, format: { with: TimeTrackingSource::UUID_PATTERN }
  validates :reason, length: { minimum: 10 }
  validate :verified_ownership

  def readonly?
    persisted?
  end

  def verified!
    raise ArgumentError, "Accounting correction evidence no longer matches this frozen line" unless valid?
    self
  end

  private

  def verified_ownership
    return if [ company, time_tracking_source, time_tracking_import, original_allocation, corrective_payroll_item ].any?(&:nil?)
    import = time_tracking_import
    original = original_allocation
    item = corrective_payroll_item
    employee = Array(import.raw_payload["employees"]).find { |row| row["source_user_id"].to_s == source_user_id }
    line = Array(employee&.dig("adjustments")).find { |row| row["source_time_entry_id"].to_s == source_time_entry_id && row["line_key"].to_s == line_key }
    identity = TimeTracking::ConnectionIdentity.validate!(source: time_tracking_source, payload: import.raw_payload)
    unless company_id == time_tracking_source.company_id && company_id == import.pay_period.company_id &&
      original.company_id == company_id && original.time_tracking_source_id == time_tracking_source_id &&
      import.time_tracking_source_id == time_tracking_source_id && identity.source_instance_id == source_instance_id &&
      import.external_batch_id == batch_id && import.external_batch_checksum == batch_checksum &&
      employee&.dig("source_user_uuid") == source_user_uuid && line == line_snapshot && line_snapshot["source_kind"] == "correction" &&
      original.verified_source_user_uuid == source_user_uuid && original.source_user_id == source_user_id &&
      original.source_time_entry_id == source_time_entry_id && original.line_key == line_key &&
      item.company_id == company_id && item.employee_id == original.employee_id &&
      item.correction_for_payroll_item_id == original.payroll_item_id && item.pay_period.committed? && !item.pay_period.voided? &&
      !original.pay_period.voided? && !original.payroll_item.voided? &&
      item.pay_period.corrects_pay_period_id == original.pay_period_id && !item.voided? &&
      item.net_pay.to_d.negative? && item.check_number.blank? &&
      total_hours == regular_hours + overtime_hours && total_hours.negative? && regular_hours <= 0 && overtime_hours <= 0 &&
      %w[total_hours regular_hours overtime_hours].all? { |key| public_send(key) == line_snapshot[key].to_d } &&
      item.hours_worked.to_d == regular_hours && item.overtime_hours.to_d == overtime_hours
      errors.add(:base, "Accounting correction ownership and exact frozen proof must reconcile")
    end
  rescue TimeTracking::ConnectionIdentity::Error => e
    errors.add(:base, e.message)
  end
end
