# frozen_string_literal: true

class CreatePayrollIntakeImports < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_intake_sessions do |t|
      t.references :company, null: false, foreign_key: true
      t.references :pay_period, null: false, foreign_key: true
      t.string :source_type, null: false
      t.string :status, null: false, default: "draft"
      t.string :source_label
      t.string :import_hash, null: false
      t.string :parser_version, null: false
      t.jsonb :warnings, null: false, default: []
      t.jsonb :totals, null: false, default: {}
      t.text :error_message
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :reviewed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :applied_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :reviewed_at
      t.datetime :applied_at

      t.timestamps
    end

    add_index :payroll_intake_sessions, [ :pay_period_id, :source_type, :import_hash ], unique: true, name: "idx_payroll_intake_sessions_idempotency"
    add_index :payroll_intake_sessions, [ :company_id, :pay_period_id, :status ], name: "idx_payroll_intake_sessions_company_period_status"
    add_index :payroll_intake_sessions, [ :source_type, :status ], name: "idx_payroll_intake_sessions_source_status"

    create_table :payroll_intake_documents do |t|
      t.references :payroll_intake_session, null: false, foreign_key: true, index: { name: "idx_payroll_intake_documents_session" }
      t.string :document_type, null: false
      t.string :filename
      t.string :content_type
      t.text :storage_reference
      t.text :text_content
      t.text :extracted_text
      t.jsonb :raw_response, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :payroll_intake_documents, [ :payroll_intake_session_id, :document_type ], name: "idx_payroll_intake_documents_session_type"

    create_table :payroll_intake_rows do |t|
      t.references :payroll_intake_session, null: false, foreign_key: true, index: { name: "idx_payroll_intake_rows_session" }
      t.references :employee, foreign_key: true
      t.references :applied_payroll_item, foreign_key: { to_table: :payroll_items, on_delete: :nullify }
      t.integer :position, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.boolean :excluded, null: false, default: false
      t.string :source_employee_name, null: false
      t.string :match_method
      t.decimal :match_confidence, precision: 5, scale: 4
      t.decimal :confidence, precision: 5, scale: 4
      t.decimal :week1_hours, precision: 8, scale: 2, null: false, default: 0
      t.decimal :week2_hours, precision: 8, scale: 2, null: false, default: 0
      t.decimal :regular_hours, precision: 8, scale: 2, null: false, default: 0
      t.decimal :overtime_hours, precision: 8, scale: 2, null: false, default: 0
      t.decimal :week1_tips, precision: 10, scale: 2, null: false, default: 0
      t.decimal :week2_tips, precision: 10, scale: 2, null: false, default: 0
      t.decimal :reported_tips, precision: 10, scale: 2, null: false, default: 0
      t.decimal :tips_paid_out, precision: 10, scale: 2, null: false, default: 0
      t.decimal :loan_deduction, precision: 10, scale: 2, null: false, default: 0
      t.jsonb :warnings, null: false, default: []
      t.jsonb :validation_errors, null: false, default: []
      t.jsonb :source_payload, null: false, default: {}
      t.jsonb :staff_overrides, null: false, default: {}

      t.timestamps
    end

    add_index :payroll_intake_rows, [ :payroll_intake_session_id, :position ], name: "idx_payroll_intake_rows_session_position"
    add_index :payroll_intake_rows, [ :payroll_intake_session_id, :employee_id ], name: "idx_payroll_intake_rows_session_employee"
    add_index :payroll_intake_rows, [ :status, :excluded ], name: "idx_payroll_intake_rows_status_excluded"
  end
end
