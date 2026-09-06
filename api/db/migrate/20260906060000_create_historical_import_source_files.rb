# frozen_string_literal: true

class CreateHistoricalImportSourceFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :historical_import_source_files do |t|
      t.references :historical_import_batch, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.references :uploaded_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :original_filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :sha256, null: false
      t.string :storage_key, null: false
      t.string :report_type, null: false
      t.integer :position, null: false
      t.string :verification_status, null: false, default: "verified"
      t.datetime :verified_at
      t.string :verification_error

      t.timestamps
    end

    add_index :historical_import_source_files, :storage_key, unique: true
    add_index :historical_import_source_files,
              %i[historical_import_batch_id position],
              unique: true,
              name: "idx_historical_source_files_batch_position"
    add_check_constraint :historical_import_source_files,
                         "byte_size > 0",
                         name: "historical_source_files_positive_size"
    add_check_constraint :historical_import_source_files,
                         "verification_status IN ('verified', 'failed')",
                         name: "historical_source_files_verification_status"
  end
end
