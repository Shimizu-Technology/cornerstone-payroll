# frozen_string_literal: true

# Pending records survive queue outages and worker termination. Reconcile a
# bounded page on the existing scheduler; updated_at is the retry cooldown.
class ClientDocumentScanRecoveryJob < ApplicationJob
  queue_as :default

  STALE_AFTER = 15.minutes
  BATCH_SIZE = 100

  def perform
    return unless ClientDocumentScanner.adapter.initial_status == "pending"

    ClientDocument.where(scan_status: "pending", updated_at: ...STALE_AFTER.ago)
      .order(:updated_at, :id).limit(BATCH_SIZE).each do |document|
      claimed = ClientDocument.where(id: document.id, scan_status: "pending", updated_at: document.updated_at)
        .update_all(updated_at: Time.current)
      next unless claimed == 1

      begin
        ScanClientDocumentJob.perform_later(document.id)
      rescue StandardError => e
        Rails.logger.error("Client document scan recovery enqueue failed for #{document.id}: #{e.class}")
      end
    end
  end
end
