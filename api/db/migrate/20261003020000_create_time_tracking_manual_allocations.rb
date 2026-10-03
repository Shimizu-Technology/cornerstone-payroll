# frozen_string_literal: true

class CreateTimeTrackingManualAllocations < ActiveRecord::Migration[8.0]
  def change
    create_table :time_tracking_manual_allocations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true
      t.references :payroll_item, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.uuid :source_user_uuid, null: false
      t.string :source_time_entry_id, null: false
      t.integer :source_time_entry_version, null: false
      t.date :original_work_date, null: false
      t.decimal :regular_hours, precision: 8, scale: 2, null: false
      t.decimal :overtime_hours, precision: 8, scale: 2, null: false
      t.text :reconciliation_note, null: false
      t.string :status, null: false, default: "pending_commit"
      t.uuid :commit_command_id, null: false
      t.uuid :issue_command_id, null: false
      t.uuid :void_command_id, null: false
      t.string :remote_allocation_id
      t.integer :remote_version
      t.text :last_sync_error
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :time_tracking_manual_allocations,
              [ :time_tracking_source_id, :source_time_entry_id, :payroll_item_id ],
              unique: true, name: "index_manual_time_allocations_on_source_entry_and_item"
    add_index :time_tracking_manual_allocations, :commit_command_id, unique: true
    add_index :time_tracking_manual_allocations, :issue_command_id, unique: true
    add_index :time_tracking_manual_allocations, :void_command_id, unique: true
    add_check_constraint :time_tracking_manual_allocations,
                         "regular_hours >= 0 AND overtime_hours >= 0 AND regular_hours + overtime_hours > 0",
                         name: "manual_time_allocation_positive_hours"
    add_check_constraint :time_tracking_manual_allocations,
                         "status IN ('pending_commit', 'committed', 'issued', 'voided')",
                         name: "manual_time_allocation_status"
  end
end
