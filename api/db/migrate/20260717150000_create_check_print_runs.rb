# frozen_string_literal: true

class CreateCheckPrintRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :check_print_runs do |t|
      t.references :company, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :confirmed_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "generated"
      t.string :check_stock_type, null: false
      t.integer :starting_slot, null: false, default: 1
      t.integer :selected_count, null: false
      t.jsonb :manifest, null: false, default: []
      t.string :storage_key, null: false
      t.string :filename, null: false
      t.string :sha256, null: false
      t.bigint :byte_size, null: false
      t.datetime :generated_at, null: false
      t.datetime :confirmed_at
      t.timestamps
    end

    add_index :check_print_runs, :storage_key, unique: true
    add_index :check_print_runs, [ :pay_period_id, :generated_at ], name: "idx_check_print_runs_period_generated"
    add_check_constraint :check_print_runs,
                         "status IN ('generated', 'confirmed')",
                         name: "check_print_runs_status_check"
    add_check_constraint :check_print_runs,
                         "starting_slot BETWEEN 1 AND 4",
                         name: "check_print_runs_starting_slot_check"
    add_check_constraint :check_print_runs,
                         "selected_count > 0",
                         name: "check_print_runs_selected_count_check"
    add_check_constraint :check_print_runs,
                         "byte_size > 0",
                         name: "check_print_runs_byte_size_check"
  end
end
