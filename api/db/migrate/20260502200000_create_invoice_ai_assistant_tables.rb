# frozen_string_literal: true

class CreateInvoiceAiAssistantTables < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_chat_sessions do |t|
      t.references :company, null: false, foreign_key: true
      t.references :invoice_recipient, foreign_key: true
      t.references :invoice, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.string :status, null: false, default: "active"
      t.jsonb :current_preview, null: false, default: {}
      t.integer :current_preview_version, null: false, default: 0
      t.boolean :archived, null: false, default: false
      t.timestamps

      t.index [ :company_id, :archived, :updated_at ], name: "idx_invoice_chat_sessions_on_company_archive_updated"
      t.check_constraint "status IN ('active', 'invoice_created', 'archived')", name: "check_invoice_chat_sessions_status"
    end

    create_table :invoice_chat_messages do |t|
      t.references :invoice_chat_session, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false
      t.text :content, null: false
      t.jsonb :image_urls, null: false, default: []
      t.jsonb :preview, null: false, default: {}
      t.integer :preview_version
      t.boolean :has_preview, null: false, default: false
      t.timestamps

      t.index [ :invoice_chat_session_id, :created_at ], name: "idx_invoice_chat_messages_on_session_created"
      t.check_constraint "role IN ('user', 'assistant')", name: "check_invoice_chat_messages_role"
    end
  end
end
