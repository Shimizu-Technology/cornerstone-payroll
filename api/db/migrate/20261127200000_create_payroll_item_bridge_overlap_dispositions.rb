# frozen_string_literal: true

# A native paycheck paid on or before an applied opening balance's through
# date may be its own payment or the same payment the import already holds.
# Staff (or unambiguous payment evidence) record which, once per paycheck and
# import; statement YTD and W-2GU read only the recorded answer. Append-only,
# like legacy dispositions, and company-protected like the payroll tables.
class CreatePayrollItemBridgeOverlapDispositions < ActiveRecord::Migration[8.1]
  DECISIONS = %w[distinct duplicate_of_imported].freeze
  SOURCES = %w[payment_evidence staff_review].freeze

  def up
    execute "SET LOCAL lock_timeout = '5s'"
    create_table :payroll_item_bridge_overlap_dispositions do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: true
      t.references :payroll_item, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :historical_import_batch, null: false, foreign_key: { on_delete: :restrict }, index: true
      # The imported paycheck a duplicate repeats; nil for a distinct payment.
      t.references :historical_paycheck, foreign_key: { on_delete: :restrict }, index: true
      t.references :created_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }, index: true
      t.string :decision, null: false, limit: 40
      t.string :source, null: false, limit: 40
      t.text :reason, null: false
      t.jsonb :evidence, null: false, default: {}
      t.string :evidence_digest, null: false, limit: 64
      t.timestamps null: false

      t.index %i[payroll_item_id historical_import_batch_id], unique: true, name: "idx_bridge_overlap_dispositions_item_batch"
      t.check_constraint "decision IN (#{DECISIONS.map { |value| "'#{value}'" }.join(', ')})", name: "bridge_overlap_dispositions_decision_check"
      t.check_constraint "source IN (#{SOURCES.map { |value| "'#{value}'" }.join(', ')})", name: "bridge_overlap_dispositions_source_check"
      t.check_constraint "(decision = 'duplicate_of_imported') = (historical_paycheck_id IS NOT NULL)",
        name: "bridge_overlap_dispositions_duplicate_names_paycheck"
      t.check_constraint "evidence_digest ~ '^[0-9a-f]{64}$'", name: "bridge_overlap_dispositions_digest_check"
      t.check_constraint "jsonb_typeof(evidence) = 'object'", name: "bridge_overlap_dispositions_evidence_object"
    end

    execute <<~SQL
      CREATE FUNCTION prevent_payroll_item_bridge_overlap_disposition_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'payroll_item_bridge_overlap_dispositions are append-only';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER payroll_item_bridge_overlap_dispositions_append_only
      BEFORE UPDATE OR DELETE ON payroll_item_bridge_overlap_dispositions
      FOR EACH ROW EXECUTE FUNCTION prevent_payroll_item_bridge_overlap_disposition_mutation();
    SQL
    stage_company_policy!
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    drop_table :payroll_item_bridge_overlap_dispositions
    execute "DROP FUNCTION IF EXISTS prevent_payroll_item_bridge_overlap_disposition_mutation()"
  end

  private

  def stage_company_policy!
    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'payroll_item_bridge_overlap_dispositions', NULL, NULL, false)"
    return unless connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'payroll_items'::regclass")

    execute "ALTER TABLE payroll_item_bridge_overlap_dispositions ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE payroll_item_bridge_overlap_dispositions FORCE ROW LEVEL SECURITY"
  end
end
