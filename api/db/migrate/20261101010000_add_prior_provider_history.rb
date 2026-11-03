# frozen_string_literal: true

class AddPriorProviderHistory < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :historical_import_batches, "source_system = 'quickbooks_online'", name: "historical_import_batches_source"
    add_check_constraint :historical_import_batches, "source_system IN ('quickbooks_online', 'prior_provider')", name: "historical_import_batches_source"
    remove_check_constraint :historical_import_batches, "status IN ('previewed', 'applied', 'locked', 'failed')", name: "historical_import_batches_status"
    add_check_constraint :historical_import_batches, "status IN ('previewed', 'applied', 'locked', 'failed', 'reversed')", name: "historical_import_batches_status"
    change_column_null :historical_ytd_bridges, :historical_client_bootstrap_id, true
    remove_check_constraint :historical_ytd_bridges, "status IN ('previewed', 'applied')", name: "historical_ytd_bridges_status_check"
    add_check_constraint :historical_ytd_bridges, "status IN ('previewed', 'applied', 'reversed')", name: "historical_ytd_bridges_status_check"
    remove_check_constraint :historical_ytd_bridges, "(status = 'applied' AND applied_at IS NOT NULL AND applied_by_id IS NOT NULL AND apply_acknowledgement IS NOT NULL) OR (status = 'previewed' AND applied_at IS NULL AND applied_by_id IS NULL AND apply_acknowledgement IS NULL)", name: "historical_ytd_bridges_status_audit_fields"
    add_check_constraint :historical_ytd_bridges,
      "(status IN ('applied', 'reversed') AND applied_at IS NOT NULL AND applied_by_id IS NOT NULL AND apply_acknowledgement IS NOT NULL) OR " \
      "(status = 'previewed' AND applied_at IS NULL AND applied_by_id IS NULL AND apply_acknowledgement IS NULL)",
      name: "historical_ytd_bridges_status_audit_fields"

    create_table :prior_provider_history_onboardings do |t|
      t.references :company, null: false, foreign_key: true
      t.references :historical_import_batch, null: false, foreign_key: true, index: { unique: true, name: "idx_prior_provider_batch" }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :activated_by, foreign_key: { to_table: :users }
      t.references :reversed_by, foreign_key: { to_table: :users }
      t.integer :tax_year, null: false
      t.date :takeover_on, null: false
      t.string :status, null: false, default: "converted"
      t.string :idempotency_key, null: false
      t.string :preview_digest, null: false
      t.jsonb :evidence, null: false, default: {}
      t.jsonb :filing_before, null: false, default: []
      t.jsonb :filing_after, null: false, default: []
      t.datetime :activated_at
      t.datetime :reversed_at
      t.text :reversal_reason
      t.timestamps
    end
    add_index :prior_provider_history_onboardings, [ :id, :company_id ], unique: true, name: "idx_prior_provider_tenant_key"
    add_foreign_key :prior_provider_history_onboardings, :historical_import_batches,
      column: [ :historical_import_batch_id, :company_id ], primary_key: [ :id, :company_id ], name: "fk_prior_provider_batch_tenant"
    add_reference :historical_ytd_bridges, :prior_provider_history_onboarding, foreign_key: true, index: { name: "idx_historical_bridge_existing_roster" }
    add_foreign_key :historical_ytd_bridges, :prior_provider_history_onboardings,
      column: [ :prior_provider_history_onboarding_id, :company_id ], primary_key: [ :id, :company_id ], name: "fk_bridge_prior_provider_tenant"
    add_check_constraint :historical_ytd_bridges, "num_nonnulls(historical_client_bootstrap_id, prior_provider_history_onboarding_id) = 1", name: "historical_bridge_roster_contract"
    add_index :prior_provider_history_onboardings, [ :company_id, :idempotency_key ], unique: true, name: "idx_prior_provider_idempotency"
    add_index :prior_provider_history_onboardings, [ :company_id, :tax_year ], unique: true, where: "status != 'reversed'", name: "idx_prior_provider_one_active_year"
    add_check_constraint :prior_provider_history_onboardings, "status IN ('converted', 'active', 'reversed')", name: "prior_provider_status"
    add_check_constraint :prior_provider_history_onboardings, "tax_year BETWEEN 2000 AND 2200 AND EXTRACT(YEAR FROM takeover_on) = tax_year", name: "prior_provider_year"
    add_reference :pay_periods, :retired_to_historical_import_batch, foreign_key: { to_table: :historical_import_batches }, index: { name: "idx_pay_periods_retired_history" }
    add_foreign_key :pay_periods, :historical_import_batches,
      column: [ :retired_to_historical_import_batch_id, :company_id ], primary_key: [ :id, :company_id ], name: "fk_retired_history_tenant"
    add_check_constraint :pay_periods, "(status = 'retired_history') = (retired_to_historical_import_batch_id IS NOT NULL)", name: "pay_periods_history_retirement"
  end
end
