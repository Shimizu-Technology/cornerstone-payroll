# frozen_string_literal: true

module PayrollReview
  class PackagePresenter
    def self.call(review_package, include_source_manifest: true, include_notification_status: false)
      return nil unless review_package

      {
        id: review_package.id,
        revision: review_package.revision,
        schema_version: review_package.schema_version,
        calculation_checksum: review_package.calculation_checksum,
        checksum_short: review_package.calculation_checksum.first(12),
        status: review_package.changes_requested_at && review_package.pending? ? "changes_requested" : review_package.status,
        published_at: review_package.published_at,
        superseded_at: review_package.superseded_at,
        supersession_reason: review_package.supersession_reason,
        changes_requested_at: review_package.changes_requested_at,
        changes_requested_by_name: review_package.changes_requested_by&.name,
        change_request_note: review_package.change_request_note,
        generated_at: review_package.generated_at,
        generated_by_name: review_package.generated_by&.name,
        approved_at: review_package.approved_at,
        approved_by_id: review_package.approved_by_id,
        approved_by_name: review_package.approved_by&.name,
        approval_recorded_by_name: review_package.approval_recorded_by&.name,
        approval_method: review_package.approval_method,
        approval_notes: review_package.approval_notes,
        approval_evidence_reference: review_package.approval_evidence_reference,
        acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT
      }.tap do |payload|
        payload[:source_manifest] = review_package.source_manifest if include_source_manifest
        if include_notification_status
          notification_status = decision_notification_status(review_package)
          payload[:notification_status] = notification_status
          payload[:notification_queued] = notification_status.nil? ? nil : notification_status == "queued"
        end
      end
    end

    def self.decision_notification_status(review_package)
      return nil unless review_package.approved? || review_package.changes_requested_at.present?

      # Derive status from a single read so a concurrent pending -> sent
      # transition cannot momentarily look like not_sent. Foreign-account
      # suppressed extra addresses mirror the same queued -> sent lifecycle as
      # an unregistered extra address so tenant responses stay indistinguishable.
      rows = PortalNotificationDelivery.joins(:portal_notification_event)
        .where(
          company_id: review_package.company_id,
          portal_notification_events: { dedupe_key: "payroll_review_decided:#{review_package.id}" }
        )
        .pluck(:status, :skip_reason, :deliver_after)

      now = Time.current
      return "sent" if rows.any? { |status, _reason, _after| status == "sent" }
      if rows.any? { |status, reason, after| status == "skipped" && reason == "foreign_account_suppressed" && after <= now }
        return "sent"
      end
      return "not_sent" unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured?

      queued = rows.any? do |status, reason, after|
        status == "pending" || (status == "skipped" && reason == "foreign_account_suppressed" && after > now)
      end
      queued ? "queued" : "not_sent"
    end

    def self.decision_notification_queued?(review_package)
      status = decision_notification_status(review_package)
      status.nil? ? nil : status == "queued"
    end
  end
end
