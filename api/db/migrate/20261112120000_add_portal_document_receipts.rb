# frozen_string_literal: true

class AddPortalDocumentReceipts < ActiveRecord::Migration[8.1]
  def change
    add_reference :client_documents, :reviewed_by, foreign_key: { to_table: :users }
    add_column :client_documents, :reviewed_at, :datetime
    create_table :portal_document_read_receipts do |t|
      t.references :client_document, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.datetime :opened_at, null: false
      t.index [ :client_document_id, :user_id ], unique: true, name: 'idx_portal_document_reads_unique'
    end
  end
end
