# frozen_string_literal: true

class TimeTrackingFinancialCorrectionLink < ApplicationRecord
  belongs_to :original_allocation, class_name: "TimeTrackingEntryAllocation"
  belongs_to :predecessor_payroll_item, class_name: "PayrollItem"
  belongs_to :payroll_item
  has_many :aire_payroll_entry_acknowledgements, foreign_key: :financial_correction_link_id, dependent: :restrict_with_error

  validates :command_id, :event_id, :payload, :request_digest, presence: true
  validates :command_id, :event_id, uniqueness: true
  validates :original_allocation_id, uniqueness: { scope: :predecessor_payroll_item_id }
  validate :owner_and_payload_match
  validate :acceptance_pair

  delegate :time_tracking_import_id, :time_tracking_source, :source_time_entry_id, :line_key,
    :verified_source_user_uuid, :source_kind, :total_hours, :regular_hours, :overtime_hours, to: :original_allocation

  def accepted?
    accepted_at.present? && accepted_receipt.present?
  end

  def accept!(receipt)
    TimeTracking::Client.new(original_allocation.time_tracking_source).validate_financial_correction_receipt!(receipt, expected: payload)
    with_lock do
      raise TimeTracking::Client::Error, "The Source correction receipt changed" if accepted? && accepted_receipt != receipt
      update!(accepted_receipt: receipt, accepted_at: accepted_at || Time.current) unless accepted?
    end
  end

  def payment_payload(event_id:, status:, occurred_at:, payment_method:, payment_reference:, payment_effective_on:)
    payload.except("obligation_correction").merge(
      "event_id" => event_id, "status" => status, "occurred_at" => occurred_at.utc.iso8601(6),
      "payment_method" => payment_method, "payment_reference" => payment_reference,
      "payment_effective_on" => payment_effective_on&.iso8601
    ).compact
  end

  private

  def acceptance_pair
    empty = accepted_receipt == {} && accepted_at.nil?
    complete = accepted_receipt.is_a?(Hash) && accepted_receipt.present? && accepted_at.present?
    errors.add(:base, "Source receipt and acceptance time must be recorded together") unless empty || complete
  end

  def owner_and_payload_match
    unless payload.is_a?(Hash) && payload["obligation_correction"].is_a?(Hash)
      errors.add(:payload, "must include a structured correction command")
      return
    end
    return if original_allocation.nil? || payroll_item.nil? || predecessor_payroll_item.nil?
    row = original_allocation
    command = payload["obligation_correction"].to_h
    valid = payroll_item.company_id == row.company_id && predecessor_payroll_item.company_id == row.company_id &&
      payroll_item.employee_id == row.employee_id && predecessor_payroll_item.employee_id == row.employee_id &&
      payload["external_pay_period_id"] == payroll_item.pay_period_id.to_s && payload["external_payroll_item_id"] == payroll_item.id.to_s &&
      payload["source_time_entry_id"] == row.source_time_entry_id && payload["source_line_key"] == row.line_key &&
      payload["source_user_uuid"] == row.verified_source_user_uuid && payload["source_kind"] == row.source_kind &&
      %w[total_hours regular_hours overtime_hours].all? { |field| payload[field].to_d == row.public_send(field) } &&
      command["batch_checksum"] == row.time_tracking_import.external_batch_checksum &&
      command["source_instance_id"] == row.time_tracking_source.expected_source_instance_id &&
      command["source_work_date"] == row.original_work_date.iso8601 &&
      command["command_id"] == command_id && payload["event_id"] == event_id &&
      command.dig("predecessor", "external_payroll_item_id") == predecessor_payroll_item.id.to_s &&
      request_digest == TimeTracking::CanonicalPayload.checksum(payload)
    errors.add(:base, "Financial correction Source lineage must match the exact frozen owner") unless valid
  end
end
