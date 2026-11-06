# frozen_string_literal: true

class CreateAireHistoryOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :aire_history_operations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :kind, null: false
      t.string :status, null: false, default: "queued"
      t.string :request_key, null: false
      t.jsonb :arguments, null: false, default: {}
      t.jsonb :result
      t.text :error
      t.jsonb :source_changes, null: false, default: []
      t.datetime :finished_at
      t.timestamps
    end
    add_index :aire_history_operations, [ :actor_id, :time_tracking_source_id, :request_key ], unique: true,
      name: "idx_aire_history_operation_request"
    add_check_constraint :aire_history_operations, "kind IN ('preview', 'approve')", name: "aire_history_operation_kind"
    add_check_constraint :aire_history_operations, "status IN ('queued', 'completed', 'failed')", name: "aire_history_operation_status"
  end
end
