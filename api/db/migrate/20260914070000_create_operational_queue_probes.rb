# frozen_string_literal: true

class CreateOperationalQueueProbes < ActiveRecord::Migration[8.1]
  def change
    create_table :operational_queue_probes do |t|
      t.uuid :probe_id, null: false
      t.integer :attempt_count, null: false, default: 0
      t.integer :effect_count, null: false, default: 0
      t.datetime :completed_at
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :operational_queue_probes, :probe_id, unique: true
    add_check_constraint :operational_queue_probes,
                         "attempt_count >= 0",
                         name: "operational_queue_probes_attempt_count_nonnegative"
    add_check_constraint :operational_queue_probes,
                         "effect_count BETWEEN 0 AND 1",
                         name: "operational_queue_probes_effect_count_range"
    add_check_constraint :operational_queue_probes,
                         "(effect_count = 0 AND completed_at IS NULL) OR (effect_count = 1 AND completed_at IS NOT NULL)",
                         name: "operational_queue_probes_completion_consistent"
  end
end
