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
          payload[:notification_queued] = decision_notification_queued?(review_package)
        end
      end
    end

    def self.decision_notification_queued?(review_package)
      return nil unless review_package.approved? || review_package.changes_requested_at.present?

      deliveries = PortalNotificationDelivery.joins(:portal_notification_event)
        .where(
          company_id: review_package.company_id,
          portal_notification_events: { dedupe_key: "payroll_review_decided:#{review_package.id}" }
        )
      return true if deliveries.where(status: "sent").exists?
      return false unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured?

      deliveries.where(status: "pending").exists?
    end
  end
end
