# frozen_string_literal: true

class CreatePayrollGoLiveReviews < ActiveRecord::Migration[8.0]
  def change
    add_column :pay_periods, :parallel_run, :boolean, default: false, null: false
    add_index :pay_periods, [ :company_id, :parallel_run, :pay_date ], name: "idx_pay_periods_parallel_runs"
    add_check_constraint :pay_periods,
      "parallel_run = FALSE OR status <> 'committed'",
      name: "pay_periods_parallel_runs_not_committed"

    create_table :payroll_go_live_reviews do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :source_company, null: false, foreign_key: { to_table: :companies, on_delete: :restrict }
      t.references :historical_import_batch, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :created_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :setup_applied_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :technical_signed_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :operations_signed_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.date :effective_on, null: false
      t.string :status, null: false, default: "draft"
      t.string :plan_digest, null: false
      t.jsonb :setup_summary, null: false, default: {}
      t.jsonb :setup_plan, null: false, default: {}
      t.jsonb :warnings, null: false, default: []
      t.jsonb :validation_errors, null: false, default: []
      t.jsonb :attestations, null: false, default: {}
      t.text :review_notes
      t.datetime :setup_applied_at
      t.datetime :technical_signed_at
      t.datetime :operations_signed_at
      t.datetime :approved_at
      t.timestamps
    end

    add_check_constraint :payroll_go_live_reviews,
      "status IN ('draft', 'setup_applied', 'approved')",
      name: "payroll_go_live_reviews_status_check"
    add_check_constraint :payroll_go_live_reviews,
      "jsonb_typeof(setup_summary) = 'object' AND jsonb_typeof(setup_plan) = 'object' AND jsonb_typeof(attestations) = 'object'",
      name: "payroll_go_live_reviews_object_json_check"
    add_check_constraint :payroll_go_live_reviews,
      "jsonb_typeof(warnings) = 'array' AND jsonb_typeof(validation_errors) = 'array'",
      name: "payroll_go_live_reviews_array_json_check"

    create_table :payroll_parallel_run_reviews do |t|
      t.references :payroll_go_live_review, null: false, foreign_key: { on_delete: :restrict }, index: { name: "idx_parallel_reviews_go_live" }
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :recorded_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :source_system, null: false, default: "quickbooks"
      t.string :result, null: false
      t.integer :source_employee_count, null: false
      t.integer :cornerstone_employee_count, null: false
      t.decimal :source_gross_pay, precision: 15, scale: 2, null: false
      t.decimal :source_net_pay, precision: 15, scale: 2, null: false
      t.decimal :source_taxes, precision: 15, scale: 2, null: false
      t.decimal :source_deductions, precision: 15, scale: 2, null: false
      t.decimal :cornerstone_gross_pay, precision: 15, scale: 2, null: false
      t.decimal :cornerstone_net_pay, precision: 15, scale: 2, null: false
      t.decimal :cornerstone_taxes, precision: 15, scale: 2, null: false
      t.decimal :cornerstone_deductions, precision: 15, scale: 2, null: false
      t.jsonb :differences, null: false, default: {}
      t.text :notes
      t.timestamps
    end

    add_index :payroll_parallel_run_reviews,
      [ :payroll_go_live_review_id, :id ],
      name: "idx_parallel_reviews_chronological"
    add_check_constraint :payroll_parallel_run_reviews,
      "result IN ('pass', 'fail')",
      name: "payroll_parallel_run_reviews_result_check"
    add_check_constraint :payroll_parallel_run_reviews,
      "source_system IN ('quickbooks')",
      name: "payroll_parallel_run_reviews_source_check"
    add_check_constraint :payroll_parallel_run_reviews,
      "jsonb_typeof(differences) = 'object'",
      name: "payroll_parallel_run_reviews_differences_check"
  end
end
