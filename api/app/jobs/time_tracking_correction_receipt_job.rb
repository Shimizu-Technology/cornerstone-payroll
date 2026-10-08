# frozen_string_literal: true

class TimeTrackingCorrectionReceiptJob < ApplicationJob
  queue_as :default
  retry_on TimeTracking::Client::Error, wait: :polynomially_longer, attempts: 8

  def perform(receipt_id)
    receipt = TimeTrackingCorrectionReceipt.find(receipt_id)
    return if receipt.delivered_at.present?
    disposition = receipt.time_tracking_correction_disposition.verified!
    raise TimeTracking::Client::Error, "Source is inactive; restore the verified connection before delivering its accounting receipt" unless disposition.time_tracking_source.active?
    raise TimeTracking::Client::Error, "Accounting receipt proof no longer matches the disposition" unless receipt.valid?
    TimeTracking::Client.new(disposition.time_tracking_source).record_accounting_correction_event(**receipt.payload.deep_symbolize_keys)
    receipt.update!(delivered_at: Time.current, last_error: nil)
  rescue TimeTracking::Client::Error, ArgumentError, ActiveRecord::RecordInvalid => e
    receipt&.update_columns(last_error: e.message, updated_at: Time.current)
    raise TimeTracking::Client::Error, e.message
  end
end
