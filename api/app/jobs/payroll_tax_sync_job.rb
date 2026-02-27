# frozen_string_literal: true

class PayrollTaxSyncJob < ApplicationJob
  queue_as :default

  # Exponential backoff: 30s, 2m, 8m, 32m, ~2h
  retry_on PayrollTaxSyncService::SyncError,
           wait: :polynomially_longer,
           attempts: PayPeriod::MAX_SYNC_ATTEMPTS

  discard_on PayrollTaxSyncService::ConfigurationError

  def perform(pay_period_id)
    pay_period = PayPeriod.find_by(id: pay_period_id)
    return unless pay_period&.committed?

    # Skip if already synced
    return if pay_period.tax_sync_status == "synced"

    PayrollTaxSyncService.new(pay_period).sync!
  end
end
