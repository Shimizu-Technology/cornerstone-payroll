# frozen_string_literal: true

class CreateHistoricalPaycheckAdjustments < ActiveRecord::Migration[8.0]
  MONEY_FIELDS = %i[
    gross_pay adjusted_gross pretax_deductions employee_taxes federal_income_tax
    social_security_tax medicare_tax after_tax_deductions net_pay employer_taxes
    employer_contributions total_payroll_cost
  ].freeze
  BREAKDOWN_FIELDS = %i[
    hours_breakdown earnings_breakdown pretax_deduction_breakdown
    after_tax_deduction_breakdown employee_tax_breakdown employer_tax_breakdown
    employer_contribution_breakdown
  ].freeze

  def up
    add_index :historical_paychecks, [ :id, :company_id ], unique: true,
              name: "idx_historical_paychecks_tenant_key"

    create_table :historical_paycheck_adjustments do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.references :historical_paycheck, null: false, foreign_key: true, index: false
      t.references :reverses_adjustment, index: false
      t.references :created_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }, index: false
      t.string :kind, null: false
      t.date :effective_pay_date, null: false
      t.integer :filing_year, null: false
      t.integer :filing_quarter, null: false
      t.text :reason, null: false
      t.string :external_reference
      t.jsonb :evidence_metadata, null: false, default: {}
      t.string :idempotency_key, null: false
      t.decimal :hours_total, precision: 12, scale: 4, null: false, default: 0
      MONEY_FIELDS.each do |field|
        t.decimal field, precision: 15, scale: 2, null: false, default: 0
      end
      BREAKDOWN_FIELDS.each { |field| t.jsonb field, null: false, default: [] }
      t.timestamps
    end

    add_index :historical_paycheck_adjustments, [ :company_id, :idempotency_key ], unique: true,
              name: "idx_historical_adjustments_idempotency"
    add_index :historical_paycheck_adjustments, [ :company_id, :effective_pay_date ],
              name: "idx_historical_adjustments_company_date"
    add_index :historical_paycheck_adjustments, :historical_paycheck_id,
              name: "idx_historical_adjustments_paycheck"
    add_index :historical_paycheck_adjustments, :created_by_id,
              name: "idx_historical_adjustments_creator"
    add_index :historical_paycheck_adjustments, :reverses_adjustment_id, unique: true,
              where: "reverses_adjustment_id IS NOT NULL",
              name: "idx_historical_adjustments_one_reversal"
    add_index :historical_paycheck_adjustments, [ :id, :company_id ], unique: true,
              name: "idx_historical_adjustments_tenant_key"
    add_check_constraint :historical_paycheck_adjustments,
                         "kind IN ('correction', 'void', 'reversal')",
                         name: "historical_adjustments_kind_check"
    add_check_constraint :historical_paycheck_adjustments,
                         "filing_year BETWEEN 2000 AND 2200 AND filing_quarter BETWEEN 1 AND 4",
                         name: "historical_adjustments_filing_period_check"
    add_check_constraint :historical_paycheck_adjustments,
                         "jsonb_typeof(evidence_metadata) = 'object'",
                         name: "historical_adjustments_evidence_object"
    BREAKDOWN_FIELDS.each do |field|
      add_check_constraint :historical_paycheck_adjustments,
                           "jsonb_typeof(#{field}) = 'array'",
                           name: "historical_adjustments_#{field.to_s.sub('_breakdown', '')}_array"
    end
    add_foreign_key :historical_paycheck_adjustments, :historical_paychecks,
                    column: [ :historical_paycheck_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_adjustments_paycheck_tenant"
    add_foreign_key :historical_paycheck_adjustments, :historical_paycheck_adjustments,
                    column: [ :reverses_adjustment_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_adjustments_reversal_tenant"

    create_table :historical_paycheck_adjustment_events do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.references :historical_paycheck_adjustment, null: false, foreign_key: true, index: false
      t.references :historical_ytd_bridge, index: false
      t.references :created_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }, index: false
      t.string :event_type, null: false
      t.jsonb :metadata, null: false, default: {}
      t.text :note
      t.datetime :created_at, null: false
    end
    add_index :historical_paycheck_adjustment_events, :historical_paycheck_adjustment_id,
              name: "idx_historical_adjustment_events_adjustment"
    add_index :historical_paycheck_adjustment_events, [ :company_id, :created_at ],
              name: "idx_historical_adjustment_events_company_time"
    add_index :historical_paycheck_adjustment_events, :historical_ytd_bridge_id,
              name: "idx_historical_adjustment_events_bridge"
    add_index :historical_paycheck_adjustment_events, :created_by_id,
              name: "idx_historical_adjustment_events_creator"
    add_check_constraint :historical_paycheck_adjustment_events,
                         "event_type IN ('filing_reviewed_no_amendment', 'filing_amendment_required', 'filing_amendment_filed_external', 'filing_review_reopened', 'downstream_impact_acknowledged', 'ytd_revision_activated')",
                         name: "historical_adjustment_events_type_check"
    add_check_constraint :historical_paycheck_adjustment_events,
                         "jsonb_typeof(metadata) = 'object'",
                         name: "historical_adjustment_events_metadata_object"
    add_foreign_key :historical_paycheck_adjustment_events, :historical_paycheck_adjustments,
                    column: [ :historical_paycheck_adjustment_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_adjustment_events_tenant"
    add_foreign_key :historical_paycheck_adjustment_events, :historical_ytd_bridges,
                    column: [ :historical_ytd_bridge_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_adjustment_events_bridge_tenant"

    remove_index :historical_ytd_bridges, name: "index_historical_ytd_bridges_on_historical_import_batch_id"
    remove_index :historical_ytd_bridges, name: "index_historical_ytd_bridges_on_historical_client_bootstrap_id"
    add_column :historical_ytd_bridges, :revision, :integer, null: false, default: 1
    add_reference :historical_ytd_bridges, :supersedes_historical_ytd_bridge, index: false
    add_foreign_key :historical_ytd_bridges, :historical_ytd_bridges,
                    column: [ :supersedes_historical_ytd_bridge_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_historical_ytd_bridges_supersedes_tenant"
    add_index :historical_ytd_bridges, [ :historical_import_batch_id, :revision ], unique: true,
              name: "idx_historical_ytd_bridges_batch_revision"
    add_index :historical_ytd_bridges, :historical_client_bootstrap_id,
              name: "idx_historical_ytd_bridges_bootstrap"
    add_index :historical_ytd_bridges, :supersedes_historical_ytd_bridge_id, unique: true,
              where: "supersedes_historical_ytd_bridge_id IS NOT NULL",
              name: "idx_historical_ytd_bridges_one_successor"
    add_check_constraint :historical_ytd_bridges, "revision > 0",
                         name: "historical_ytd_bridges_revision_positive"
  end

  def down
    if select_value(<<~SQL)
      SELECT 1
      FROM historical_ytd_bridges
      GROUP BY historical_import_batch_id
      HAVING COUNT(*) > 1
      LIMIT 1
    SQL
      raise ActiveRecord::IrreversibleMigration,
            "Cannot roll back historical adjustments after multiple YTD bridge revisions exist"
    end

    remove_check_constraint :historical_ytd_bridges, name: "historical_ytd_bridges_revision_positive"
    remove_index :historical_ytd_bridges, name: "idx_historical_ytd_bridges_one_successor"
    remove_index :historical_ytd_bridges, name: "idx_historical_ytd_bridges_bootstrap"
    remove_index :historical_ytd_bridges, name: "idx_historical_ytd_bridges_batch_revision"
    remove_foreign_key :historical_ytd_bridges, name: "fk_historical_ytd_bridges_supersedes_tenant"
    remove_reference :historical_ytd_bridges, :supersedes_historical_ytd_bridge
    remove_column :historical_ytd_bridges, :revision
    add_index :historical_ytd_bridges, :historical_client_bootstrap_id, unique: true
    add_index :historical_ytd_bridges, :historical_import_batch_id, unique: true

    drop_table :historical_paycheck_adjustment_events
    drop_table :historical_paycheck_adjustments
    remove_index :historical_paychecks, name: "idx_historical_paychecks_tenant_key"
  end
end
