# frozen_string_literal: true

class CreateClientPortalThreadsAndMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :client_portal_threads do |t|
      t.references :company, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :resolved_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :subject, null: false
      t.string :status, null: false, default: "open"
      t.datetime :last_message_at
      t.datetime :client_last_read_at
      t.datetime :staff_last_read_at
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :client_portal_threads, [ :company_id, :status, :last_message_at ], name: "index_client_portal_threads_on_company_status_last_message"

    create_table :client_portal_messages do |t|
      t.references :client_portal_thread, null: false, foreign_key: true, index: { name: "index_client_portal_messages_on_thread_id" }
      t.references :company, null: false, foreign_key: true
      t.references :author, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :client_document, foreign_key: { on_delete: :nullify }
      t.text :body
      t.timestamps
    end

    add_index :client_portal_messages, [ :company_id, :created_at ], name: "index_client_portal_messages_on_company_created_at"
  end
end
