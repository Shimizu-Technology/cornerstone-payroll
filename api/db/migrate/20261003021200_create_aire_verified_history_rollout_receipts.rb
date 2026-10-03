# frozen_string_literal: true

class CreateAireVerifiedHistoryRolloutReceipts < ActiveRecord::Migration[8.0]
  def change
    create_table :aire_verified_history_rollout_receipts do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true,
                   index: { name: "idx_aire_verified_rollout_receipts_source" }
      t.string :manifest_sha256, null: false, limit: 64
      t.integer :identity_count, null: false
      t.integer :paid_source_entry_count, null: false
      t.datetime :completed_at, null: false
      t.timestamps
    end
    add_index :aire_verified_history_rollout_receipts, :manifest_sha256,
              unique: true, name: "idx_aire_verified_rollout_receipts_manifest"
  end
end
