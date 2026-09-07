# frozen_string_literal: true

class CreateHistoricalYtdBridges < ActiveRecord::Migration[8.0]
  MONEY_PRECISION = 15
  MONEY_SCALE = 2

  def change
    add_column :historical_import_batches,
               :tax_wage_reconciliation,
               :jsonb,
               null: false,
               default: {}
    # Migration 20260907121000 validates this constraint after the phased rollout.
    add_check_constraint :historical_import_batches,
                         "jsonb_typeof(tax_wage_reconciliation) = 'object'",
                         name: "historical_import_batches_tax_wage_object",
                         validate: false

    create_table :historical_tax_wage_reports do |t|
      t.references :historical_import_batch, null: false, foreign_key: true, index: false
      t.references :historical_import_source_file, null: false, foreign_key: true, index: false
      t.references :company, null: false, foreign_key: true, index: false
      t.integer :source_position, null: false
      t.string :scope, null: false
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.jsonb :tax_lines, null: false, default: {}
      t.string :report_digest, null: false
      t.timestamps
    end

    add_index :historical_tax_wage_reports,
              :historical_import_source_file_id,
              unique: true,
              name: "idx_historical_tax_reports_unique_source"
    add_index :historical_tax_wage_reports,
              [ :historical_import_batch_id, :period_start, :period_end ],
              unique: true,
              name: "idx_historical_tax_reports_unique_period"
    add_index :historical_tax_wage_reports, [ :company_id, :period_end ]
    add_check_constraint :historical_tax_wage_reports,
                         "scope IN ('quarterly', 'quarterly_year_to_date', 'annual', 'year_to_date', 'multi_year')",
                         name: "historical_tax_wage_reports_scope_check"
    add_check_constraint :historical_tax_wage_reports,
                         "period_end >= period_start",
                         name: "historical_tax_wage_reports_date_order"
    add_check_constraint :historical_tax_wage_reports,
                         "jsonb_typeof(tax_lines) = 'object'",
                         name: "historical_tax_wage_reports_lines_object"
    add_foreign_key :historical_tax_wage_reports,
                    :historical_import_batches,
                    column: [ :historical_import_batch_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_tax_reports_batch_tenant"

    create_table :historical_ytd_bridges do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.references :historical_import_batch, null: false, foreign_key: true, index: { unique: true }
      t.references :historical_client_bootstrap, null: false, foreign_key: true, index: { unique: true }
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :applied_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :status, null: false, default: "previewed"
      t.string :plan_digest, null: false
      t.jsonb :preview_summary, null: false, default: {}
      t.jsonb :reconciliation_summary, null: false, default: {}
      t.jsonb :warnings, null: false, default: []
      t.jsonb :validation_errors, null: false, default: []
      t.text :apply_acknowledgement
      t.datetime :applied_at
      t.timestamps
    end

    add_index :historical_ytd_bridges, [ :company_id, :status ]
    add_index :historical_ytd_bridges,
              [ :id, :company_id ],
              unique: true,
              name: "idx_historical_ytd_bridges_tenant_key"
    add_check_constraint :historical_ytd_bridges,
                         "status IN ('previewed', 'applied')",
                         name: "historical_ytd_bridges_status_check"
    add_check_constraint :historical_ytd_bridges,
                         "(status = 'applied' AND applied_at IS NOT NULL AND applied_by_id IS NOT NULL AND apply_acknowledgement IS NOT NULL) OR (status = 'previewed' AND applied_at IS NULL AND applied_by_id IS NULL AND apply_acknowledgement IS NULL)",
                         name: "historical_ytd_bridges_status_audit_fields"
    add_check_constraint :historical_ytd_bridges,
                         "jsonb_typeof(preview_summary) = 'object' AND jsonb_typeof(reconciliation_summary) = 'object'",
                         name: "historical_ytd_bridges_summary_objects"
    add_check_constraint :historical_ytd_bridges,
                         "jsonb_typeof(warnings) = 'array' AND jsonb_typeof(validation_errors) = 'array'",
                         name: "historical_ytd_bridges_arrays"
    add_check_constraint :historical_ytd_bridges,
                         "preview_summary ? 'through_period_end' AND preview_summary ? 'through_pay_date' AND (preview_summary ->> 'through_period_end') ~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' AND (preview_summary ->> 'through_pay_date') ~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' AND (preview_summary ->> 'through_pay_date') >= (preview_summary ->> 'through_period_end')",
                         name: "historical_ytd_bridges_boundary_order"
    add_foreign_key :historical_ytd_bridges,
                    :historical_import_batches,
                    column: [ :historical_import_batch_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_ytd_bridges_batch_tenant"

    create_table :historical_employee_ytd_balances do |t|
      t.references :historical_ytd_bridge, null: false, foreign_key: true, index: false
      t.references :company, null: false, foreign_key: true, index: false
      t.references :employee, null: false, foreign_key: true, index: false
      t.integer :tax_year, null: false
      t.date :through_pay_date, null: false
      t.date :through_period_end, null: false
      t.jsonb :source_breakdown, null: false, default: {}

      %i[
        gross_pay net_pay federal_income_tax social_security_tax medicare_tax
        additional_withholding employee_taxes pretax_deductions after_tax_deductions
        non_taxable_pay reported_tips tips_paid_out retirement roth_retirement insurance loans
        fit_taxable_wages social_security_taxable_wages social_security_taxable_tips medicare_taxable_wages
        employer_social_security_tax employer_medicare_tax employer_taxes
        employer_contributions
      ].each do |field|
        t.decimal field, precision: MONEY_PRECISION, scale: MONEY_SCALE, null: false, default: 0
      end
      t.timestamps
    end

    add_index :historical_employee_ytd_balances,
              [ :historical_ytd_bridge_id, :employee_id, :tax_year ],
              unique: true,
              name: "idx_historical_ytd_balances_unique_employee_year"
    add_index :historical_employee_ytd_balances, [ :company_id, :employee_id, :tax_year ]
    add_index :historical_employee_ytd_balances,
              [ :employee_id, :tax_year ],
              name: "idx_historical_ytd_balances_employee_year"
    add_check_constraint :historical_employee_ytd_balances,
                         "tax_year BETWEEN 2000 AND 2200",
                         name: "historical_ytd_balances_tax_year_check"
    add_check_constraint :historical_employee_ytd_balances,
                         "jsonb_typeof(source_breakdown) = 'object'",
                         name: "historical_ytd_balances_source_object"
    add_check_constraint :historical_employee_ytd_balances,
                         "through_pay_date >= through_period_end",
                         name: "historical_ytd_balances_boundary_order"
    add_foreign_key :historical_employee_ytd_balances,
                    :historical_ytd_bridges,
                    column: [ :historical_ytd_bridge_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_ytd_balances_bridge_tenant"
  end
end
