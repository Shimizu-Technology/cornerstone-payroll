# frozen_string_literal: true

# Captures the intended recipient email at enqueue, per-worker claim ownership,
# and the exact attempted payload on first send so retries resend verbatim under
# the same idempotency key and mid-dispatch destination changes can be detected.
class AddDeliveryAttemptSnapshotToPortalNotificationDeliveries < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_column :portal_notification_deliveries, :intended_recipient_email, :string
    add_column :portal_notification_deliveries, :claimed_by, :string, limit: 64
    add_column :portal_notification_deliveries, :attempted_payload, :text
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    remove_column :portal_notification_deliveries, :attempted_payload
    remove_column :portal_notification_deliveries, :claimed_by
    remove_column :portal_notification_deliveries, :intended_recipient_email
  end
end
