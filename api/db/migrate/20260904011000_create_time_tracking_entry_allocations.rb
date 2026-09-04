# frozen_string_literal: true

class CreateTimeTrackingEntryAllocations < ActiveRecord::Migration[8.1]
  def change
    create_table :time_tracking_entry_allocations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.references :time_tracking_import, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true
      t.references :payroll_item, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.string :source_user_id, null: false
      t.uuid :source_user_uuid
      t.string :source_time_entry_id, null: false
      t.string :line_key, null: false
      t.string :source_kind, null: false
      t.date :original_work_date, null: false
      t.jsonb :category_snapshot, null: false, default: {}
      t.decimal :total_hours, precision: 10, scale: 2, null: false
      t.decimal :regular_hours, precision: 10, scale: 2, null: false
      t.decimal :overtime_hours, precision: 10, scale: 2, null: false

      t.timestamps
    end

    add_index :time_tracking_entry_allocations,
              [ :time_tracking_import_id, :source_time_entry_id, :line_key ],
              unique: true,
              name: "idx_time_tracking_allocations_unique_line"
    add_index :time_tracking_entry_allocations,
              [ :time_tracking_source_id, :source_time_entry_id ],
              name: "idx_time_tracking_allocations_source_entry"
    add_index :time_tracking_entry_allocations,
              [ :pay_period_id, :employee_id ],
              name: "idx_time_tracking_allocations_period_employee"
    add_check_constraint :time_tracking_entry_allocations,
                         "source_kind IN ('current', 'carryover', 'correction')",
                         name: "time_tracking_entry_allocations_source_kind_check"
    add_check_constraint :time_tracking_entry_allocations,
                         "total_hours = regular_hours + overtime_hours",
                         name: "time_tracking_entry_allocations_hours_reconcile"
  end
end
