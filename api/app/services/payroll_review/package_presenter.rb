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
        override_reason: review_package.override_reason,
        self_override: review_package.self_override,
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

    ENQUEUE_SKIP_REASONS = %w[email_delivery_disabled email_not_configured recipient_not_allowed].freeze

    def self.decision_notification_status(review_package)
      return nil unless review_package.approved? || review_package.changes_requested_at.present?

      # Derive status from a single read so a concurrent pending -> sent
      # transition cannot momentarily look like not_sent. Tenant-visible status
      # never depends on how extra-address rows (user_id nil) turn out, so a
      # foreign-account-suppressed extra address stays indistinguishable from an
      # unregistered extra address before dispatch, after send, and through
      # transport failures and retries.
      rows = PortalNotificationDelivery.joins(:portal_notification_event)
        .where(
          company_id: review_package.company_id,
          portal_notification_events: { dedupe_key: "payroll_review_decided:#{review_package.id}" }
        )
        .pluck(:user_id, :recipient_email, :status, :skip_reason)

      account_rows = rows.select { |user_id, _email, _status, _reason| user_id.present? }
      extra_rows = rows.select { |user_id, email, _status, _reason| user_id.nil? && email.present? }

      if account_rows.any?
        return "sent" if account_rows.any? { |_user_id, _email, status, _reason| status == "sent" }
        return "not_sent" unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured?

        account_rows.any? { |_user_id, _email, status, _reason| status == "pending" } ? "queued" : "not_sent"
      elsif extra_rows.any?
        return "not_sent" unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured?

        entered_dispatch = extra_rows.any? do |_user_id, _email, status, reason|
          !(status == "skipped" && ENQUEUE_SKIP_REASONS.include?(reason))
        end
        entered_dispatch ? "queued" : "not_sent"
      else
        "not_sent"
      end
    end

    def self.decision_notification_queued?(review_package)
      status = decision_notification_status(review_package)
      status.nil? ? nil : status == "queued"
    end
  end
end
