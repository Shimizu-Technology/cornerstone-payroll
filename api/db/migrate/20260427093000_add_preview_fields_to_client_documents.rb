# frozen_string_literal: true

class AddPreviewFieldsToClientDocuments < ActiveRecord::Migration[8.1]
  def change
    change_table :client_documents, bulk: true do |t|
      t.string :preview_status, null: false, default: "pending"
      t.string :preview_file_key
      t.string :preview_content_type
      t.datetime :preview_generated_at
      t.text :preview_error
    end

    add_index :client_documents, [ :company_id, :preview_status ]
  end
end
