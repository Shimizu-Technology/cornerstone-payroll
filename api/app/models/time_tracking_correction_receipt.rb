# frozen_string_literal: true

class TimeTrackingCorrectionReceipt < ApplicationRecord
  belongs_to :time_tracking_correction_disposition
  validates :event_id, :payload, presence: true
  validates :event_id, uniqueness: true
  validate :immutable_receipt, on: :update
  validate :exact_disposition_payload

  def self.dispatch_pending!
    where(delivered_at: nil).where("enqueued_at IS NULL OR enqueued_at < ?", 30.minutes.ago).find_each(&:dispatch!)
  end

  def retryable?
    delivered_at.blank? && (last_error.present? || enqueued_at.blank? || enqueued_at < 30.minutes.ago)
  end

  def delivery_snapshot
    confirmed = delivered_at.present?
    { id: id, event_id: event_id, status: confirmed ? "confirmed" : (last_error.present? ? "error" : "pending"),
      queued_at: enqueued_at, confirmed_at: delivered_at, error: confirmed ? nil : last_error.presence,
      can_retry: retryable? }
  end

  def dispatch!(retry_failed: false)
    with_lock do
      return false if delivered_at.present?
      return false if enqueued_at.present? && enqueued_at >= 30.minutes.ago && !(retry_failed && last_error.present?)
      TimeTrackingCorrectionReceiptJob.perform_later(id)
      update!(enqueued_at: Time.current, last_error: nil)
    end
    true
  rescue StandardError => e
    with_lock { update_columns(last_error: e.message, updated_at: Time.current) if delivered_at.blank? }
    false
  end

  private

  def exact_disposition_payload
    row = time_tracking_correction_disposition
    return unless row && payload.is_a?(Hash)
    item = row.corrective_payroll_item
    expected = {
      "event_id" => event_id, "batch_id" => row.batch_id, "status" => "committed", "contract_version" => "2.0",
      "external_pay_period_id" => item.pay_period_id.to_s, "external_payroll_item_id" => item.id.to_s,
      "source_time_entry_id" => row.source_time_entry_id, "source_user_uuid" => row.source_user_uuid,
      "source_line_key" => row.line_key, "source_kind" => "correction",
      "metadata" => { "accounting_only" => true, "correction_disposition_id" => row.id.to_s,
        "original_pay_period_id" => row.original_allocation.pay_period_id.to_s,
        "original_payroll_item_id" => row.original_allocation.payroll_item_id.to_s,
        "corrective_pay_period_id" => item.pay_period_id.to_s, "corrective_payroll_item_id" => item.id.to_s }
    }
    unless expected.all? { |key, value| payload[key] == value } &&
      %w[total_hours regular_hours overtime_hours].all? { |key| BigDecimal(payload[key].to_s) == row.public_send(key) } &&
      Time.iso8601(payload["occurred_at"].to_s) == row.created_at &&
      (payload.keys - expected.keys - %w[total_hours regular_hours overtime_hours occurred_at]).empty?
      errors.add(:payload, "must prove the exact accounting disposition without payment fields")
    end
  rescue ArgumentError, TypeError
    errors.add(:payload, "contains invalid accounting correction proof")
  end

  def immutable_receipt
    if will_save_change_to_payload? || will_save_change_to_event_id? || will_save_change_to_time_tracking_correction_disposition_id?
      errors.add(:base, "Accounting correction receipt evidence is immutable")
    end
  end
end
