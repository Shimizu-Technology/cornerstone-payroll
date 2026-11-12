# frozen_string_literal: true

class CreatePortalNotifications < ActiveRecord::Migration[8.1]
  def change
    # Who receives a client's staff-side portal alerts: chosen app users and
    # extra addresses for people without an account. Administrators manage it.
    create_table :portal_notification_recipients do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :cascade }, index: false
      t.string :email
      t.references :added_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :portal_notification_recipients, [ :company_id, :user_id ], unique: true, where: "user_id IS NOT NULL",
      name: "idx_portal_notification_recipients_user"
    add_index :portal_notification_recipients, [ :company_id, :email ], unique: true, where: "email IS NOT NULL",
      name: "idx_portal_notification_recipients_email"
    add_index :portal_notification_recipients, :user_id
    add_check_constraint :portal_notification_recipients, "(user_id IS NULL) <> (email IS NULL)",
      name: "portal_notification_recipients_one_target"

    # Notification rows are derived from portal records, so they follow their
    # client or organization out of the database.
    create_table :portal_notification_events do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :cascade }
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :event_type, null: false
      t.string :category, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.string :dedupe_key, null: false
      t.string :recipient_status, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :portal_notification_events, :dedupe_key, unique: true
    add_index :portal_notification_events, [ :subject_type, :subject_id ], name: "idx_portal_notification_events_subject"
    add_index :portal_notification_events, [ :organization_id, :recipient_status, :occurred_at ],
      name: "idx_portal_notification_events_recipient_warning"

    # One ledger row per event and recipient. A row with neither a user nor an
    # address records an event that had nobody to notify.
    create_table :portal_notification_deliveries do |t|
      t.references :portal_notification_event, null: false, foreign_key: { on_delete: :cascade },
        index: { name: "idx_portal_notification_deliveries_event" }
      t.references :user, foreign_key: { on_delete: :cascade }, index: false
      t.string :recipient_email
      t.string :recipient_key, null: false
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.string :channel, null: false, default: "email"
      t.string :delivery_mode, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :deliver_after, null: false
      t.datetime :next_attempt_at
      t.datetime :claimed_at
      t.integer :attempts, null: false, default: 0
      t.string :batch_key
      t.string :skip_reason
      t.string :last_error_class
      t.string :provider_message_id
      t.datetime :sent_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :portal_notification_deliveries, [ :portal_notification_event_id, :channel, :recipient_key ], unique: true,
      name: "idx_portal_notification_deliveries_once"
    add_index :portal_notification_deliveries, [ :deliver_after, :recipient_key ], where: "status = 'pending'",
      name: "idx_portal_notification_deliveries_due"
    add_index :portal_notification_deliveries, [ :user_id, :created_at ]
    add_index :portal_notification_deliveries, :batch_key

    create_table :portal_notification_preferences do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :category, null: false
      t.string :delivery_mode, null: false
      t.timestamps
    end
    add_index :portal_notification_preferences, [ :user_id, :category ], unique: true
  end
end
