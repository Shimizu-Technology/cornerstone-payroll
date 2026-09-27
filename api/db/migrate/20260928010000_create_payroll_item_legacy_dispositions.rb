class CreatePayrollItemLegacyDispositions < ActiveRecord::Migration[8.0]
  def up
    create_table :payroll_item_legacy_dispositions do |t|
      t.references :payroll_item, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :created_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :reason, null: false
      t.string :evidence_digest, null: false
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end

    execute <<~SQL
      CREATE FUNCTION prevent_payroll_item_legacy_disposition_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'payroll_item_legacy_dispositions are append-only';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER payroll_item_legacy_dispositions_append_only
      BEFORE UPDATE OR DELETE ON payroll_item_legacy_dispositions
      FOR EACH ROW EXECUTE FUNCTION prevent_payroll_item_legacy_disposition_mutation();
    SQL
  end

  def down
    drop_table :payroll_item_legacy_dispositions
    execute "DROP FUNCTION IF EXISTS prevent_payroll_item_legacy_disposition_mutation()"
  end
end
