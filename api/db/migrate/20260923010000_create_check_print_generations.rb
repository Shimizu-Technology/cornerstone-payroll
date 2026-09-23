# frozen_string_literal: true

class CreateCheckPrintGenerations < ActiveRecord::Migration[8.1]
  def change
    create_table :check_print_generations do |t|
      t.references :company, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :printer_profile, null: false, foreign_key: true
      t.references :check_print_run, null: true, foreign_key: true
      t.string :idempotency_key, null: false
      t.string :request_digest, null: false
      t.jsonb :payroll_item_ids, null: false, default: []
      t.jsonb :non_employee_check_ids, null: false, default: []
      t.integer :printer_profile_lock_version, null: false
      t.integer :starting_slot, null: false, default: 1
      t.string :status, null: false, default: "queued"
      t.string :phase, null: false, default: "queued"
      t.integer :completed_items, null: false, default: 0
      t.integer :total_items, null: false
      t.string :error_code
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at

      t.timestamps
    end

    add_index :check_print_generations,
      [ :company_id, :requested_by_id, :idempotency_key ],
      unique: true,
      name: "idx_check_print_generations_idempotency"
    add_index :check_print_generations,
      [ :pay_period_id, :requested_by_id, :created_at ],
      name: "idx_check_print_generations_active_lookup"
    add_check_constraint :check_print_generations,
      "status IN ('queued', 'processing', 'ready', 'failed')",
      name: "check_print_generations_status_check"
    add_check_constraint :check_print_generations,
      "phase IN ('queued', 'validating', 'rendering', 'assembling', 'uploading', 'verifying', 'ready', 'failed')",
      name: "check_print_generations_phase_check"
    add_check_constraint :check_print_generations,
      "starting_slot BETWEEN 1 AND 4",
      name: "check_print_generations_starting_slot_check"
    add_check_constraint :check_print_generations,
      "completed_items >= 0 AND total_items > 0 AND completed_items <= total_items",
      name: "check_print_generations_progress_check"
  end
end
