# frozen_string_literal: true

class CreateTimeTrackingLateHoursRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :time_tracking_late_hours_runs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.references :origin_pay_period, null: false, foreign_key: { to_table: :pay_periods }
      t.references :adjustment_pay_period, null: false, foreign_key: { to_table: :pay_periods }, index: { unique: true }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.uuid :command_id, null: false
      t.jsonb :request_payload, null: false, default: {}
      t.jsonb :selection_snapshot, null: false, default: []
      t.jsonb :rate_snapshot, null: false, default: []
      t.jsonb :batch_payload, null: false, default: {}
      t.datetime :applied_at
      t.text :last_error
      t.timestamps
    end
    add_index :time_tracking_late_hours_runs, [ :time_tracking_source_id, :command_id ], unique: true, name: 'idx_late_hours_source_command'
  end
end
