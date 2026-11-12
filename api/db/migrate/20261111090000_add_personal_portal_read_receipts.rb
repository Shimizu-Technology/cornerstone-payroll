# frozen_string_literal: true

class AddPersonalPortalReadReceipts < ActiveRecord::Migration[8.1]
  def up
    add_column :client_portal_threads, :read_baseline_message_id, :bigint, null: false, default: 0
    # A thread-level migration watermark avoids a user x thread cross product.
    # Every pre-existing message starts read, independently of legacy side reads.
    execute <<~SQL
      UPDATE client_portal_threads t SET read_baseline_message_id = COALESCE(
        (SELECT MAX(id) FROM client_portal_messages m WHERE m.client_portal_thread_id = t.id), 0)
    SQL
    create_table :portal_thread_read_receipts do |t|
      t.references :client_portal_thread, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true
      t.bigint :last_displayed_message_id, null: false
      t.datetime :opened_at, null: false
      t.timestamps
    end
    add_index :portal_thread_read_receipts, [ :client_portal_thread_id, :user_id ], unique: true, name: 'index_portal_receipts_on_thread_user'
    add_column :client_portal_messages, :idempotency_key, :string, limit: 128
    add_index :client_portal_messages, [ :client_portal_thread_id, :author_id, :idempotency_key ], unique: true, name: 'index_portal_messages_on_retry_key'
  end

  def down
    remove_index :client_portal_messages, name: 'index_portal_messages_on_retry_key'
    remove_column :client_portal_messages, :idempotency_key
    drop_table :portal_thread_read_receipts
    remove_column :client_portal_threads, :read_baseline_message_id
  end
end
