# frozen_string_literal: true

class CreateQuickbooksHistoricalImports < ActiveRecord::Migration[8.1]
  def change
    create_table :historical_import_batches do |t|
      t.references :company, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }, null: true
      t.references :applied_by, foreign_key: { to_table: :users, on_delete: :nullify }, null: true
      t.references :locked_by, foreign_key: { to_table: :users, on_delete: :nullify }, null: true
      t.string :source_system, null: false, default: "quickbooks_online"
      t.string :source_label, null: false
      t.string :bundle_digest, null: false
      t.string :importer_version, null: false
      t.string :status, null: false, default: "previewed"
      t.jsonb :source_file_manifest, null: false, default: []
      t.jsonb :preview_summary, null: false, default: {}
      t.jsonb :reconciliation_summary, null: false, default: {}
      t.jsonb :warnings, null: false, default: []
      t.jsonb :validation_errors, null: false, default: []
      t.text :apply_acknowledgement
      t.datetime :applied_at
      t.datetime :locked_at
      t.timestamps
    end

    add_index :historical_import_batches,
              %i[company_id source_system bundle_digest],
              unique: true,
              name: "idx_historical_batches_unique_bundle"
    add_check_constraint :historical_import_batches,
                         "status IN ('previewed', 'applied', 'locked', 'failed')",
                         name: "historical_import_batches_status"
    add_check_constraint :historical_import_batches,
                         "source_system = 'quickbooks_online'",
                         name: "historical_import_batches_source"

    create_table :historical_workers do |t|
      t.references :historical_import_batch, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: true, foreign_key: true
      t.string :external_key, null: false
      t.string :source_name, null: false
      t.string :normalized_name, null: false
      t.string :source_status, null: false, default: "unknown"
      t.date :hire_date
      t.string :match_method
      t.decimal :match_confidence, precision: 5, scale: 4
      t.text :private_snapshot
      t.timestamps
    end

    add_index :historical_workers,
              %i[historical_import_batch_id external_key],
              unique: true,
              name: "idx_historical_workers_unique_source"
    add_index :historical_workers, %i[company_id normalized_name]
    add_check_constraint :historical_workers,
                         "source_status IN ('active', 'inactive', 'unknown')",
                         name: "historical_workers_source_status"

    create_table :historical_pay_periods do |t|
      t.references :historical_import_batch, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.string :external_key, null: false
      t.string :period_type, null: false, default: "regular"
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.date :pay_date, null: false
      t.string :source_label, null: false
      t.integer :paycheck_count, null: false, default: 0
      t.jsonb :totals, null: false, default: {}
      t.timestamps
    end

    add_index :historical_pay_periods,
              %i[historical_import_batch_id external_key],
              unique: true,
              name: "idx_historical_periods_unique_source"
    add_index :historical_pay_periods, %i[company_id pay_date]
    add_check_constraint :historical_pay_periods,
                         "period_type IN ('regular', 'opening_summary')",
                         name: "historical_pay_periods_type"
    add_check_constraint :historical_pay_periods,
                         "end_date >= start_date AND pay_date >= end_date",
                         name: "historical_pay_periods_date_order"

    create_table :historical_paychecks do |t|
      t.references :historical_import_batch, null: false, foreign_key: true
      t.references :historical_pay_period, null: false, foreign_key: true
      t.references :historical_worker, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: true, foreign_key: true
      t.string :external_key, null: false
      t.integer :source_row_number, null: false
      t.string :source_employee_name, null: false
      t.date :pay_date, null: false
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.string :payment_method
      t.string :check_number
      t.string :source_status, null: false, default: "recorded"
      t.string :reconciliation_status, null: false
      t.decimal :hours_total, precision: 12, scale: 4, null: false, default: 0
      t.decimal :gross_pay, precision: 15, scale: 2, null: false, default: 0
      t.decimal :adjusted_gross, precision: 15, scale: 2, null: false, default: 0
      t.decimal :pretax_deductions, precision: 15, scale: 2, null: false, default: 0
      t.decimal :employee_taxes, precision: 15, scale: 2, null: false, default: 0
      t.decimal :federal_income_tax, precision: 15, scale: 2, null: false, default: 0
      t.decimal :social_security_tax, precision: 15, scale: 2, null: false, default: 0
      t.decimal :medicare_tax, precision: 15, scale: 2, null: false, default: 0
      t.decimal :after_tax_deductions, precision: 15, scale: 2, null: false, default: 0
      t.decimal :net_pay, precision: 15, scale: 2, null: false, default: 0
      t.decimal :employer_taxes, precision: 15, scale: 2, null: false, default: 0
      t.decimal :employer_contributions, precision: 15, scale: 2, null: false, default: 0
      t.decimal :total_payroll_cost, precision: 15, scale: 2, null: false, default: 0
      t.jsonb :hours_breakdown, null: false, default: []
      t.jsonb :earnings_breakdown, null: false, default: []
      t.jsonb :pretax_deduction_breakdown, null: false, default: []
      t.jsonb :after_tax_deduction_breakdown, null: false, default: []
      t.jsonb :employee_tax_breakdown, null: false, default: []
      t.jsonb :employer_tax_breakdown, null: false, default: []
      t.jsonb :employer_contribution_breakdown, null: false, default: []
      t.jsonb :source_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :historical_paychecks,
              %i[historical_import_batch_id external_key],
              unique: true,
              name: "idx_historical_paychecks_unique_source"
    add_index :historical_paychecks, %i[company_id pay_date]
    add_index :historical_paychecks, %i[company_id external_key]
    add_index :historical_paychecks, %i[historical_worker_id pay_date]
    add_check_constraint :historical_paychecks,
                         "period_end >= period_start AND pay_date >= period_end",
                         name: "historical_paychecks_date_order"
    add_check_constraint :historical_paychecks,
                         "reconciliation_status IN ('matched', 'opening_summary', 'unmatched')",
                         name: "historical_paychecks_reconciliation_status"
  end
end
