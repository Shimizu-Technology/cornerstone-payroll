# frozen_string_literal: true

class CreatePortalUploadCleanups < ActiveRecord::Migration[8.1]
  def change
    create_table :portal_upload_cleanups do |t|
      # No document FK: its upload transaction was rolled back.
      t.bigint :company_id, null: false
      t.string :file_key, null: false
      t.integer :attempts, default: 0, null: false
      t.string :last_error_class
      t.datetime :completed_at
      t.timestamps
    end
    add_index :portal_upload_cleanups, :file_key, unique: true
    add_index :portal_upload_cleanups, :completed_at
  end
end
