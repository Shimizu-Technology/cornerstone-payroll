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
    # Hold the table lock from the check through the column drops so no worker
    # can claim or send a v2 row in between.
    execute "LOCK TABLE portal_notification_deliveries IN ACCESS EXCLUSIVE MODE"
    active_v2_count = select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM portal_notification_deliveries
      WHERE batch_key LIKE 'portal-notification-v2-%'
        AND (status = 'pending' OR claimed_at IS NOT NULL)
    SQL
    if active_v2_count.positive?
      raise ActiveRecord::IrreversibleMigration,
        "Cannot roll back 20261127030000 while #{active_v2_count} pending or claimed v2 portal_notification_deliveries " \
        "still hold a batch_key. Drain or clear pending v2 deliveries before rolling back."
    end

    remove_column :portal_notification_deliveries, :attempted_payload
    remove_column :portal_notification_deliveries, :claimed_by
    remove_column :portal_notification_deliveries, :intended_recipient_email
  end
end
