# frozen_string_literal: true

module TimeTracking
  class LiveSnapshotVerifier
    def self.call!(import:)
      raise ArgumentError, "This is not a pre-pay AIRE snapshot" unless import.live_snapshot?

      latest = Client.new(import.time_tracking_source).payroll_cockpit_manual_review(
        start_date: import.start_date.iso8601,
        end_date: import.end_date.iso8601,
        external_pay_period_id: import.pay_period_id
      )
      return true if LiveSnapshotPreviewService.snapshot_checksum(latest) == import.source_payload_hash

      raise ArgumentError, "AIRE hours changed since this snapshot. Refresh the import, review the differences, and recalculate payroll."
    rescue Client::Error => e
      raise ArgumentError, "Could not verify AIRE hours before payroll: #{e.message}"
    end
  end
end
