# frozen_string_literal: true

class CreatePayrollItemFicaBasisProofs < ActiveRecord::Migration[8.1]
  def up
    create_table :payroll_item_fica_basis_proofs do |t|
      t.references :payroll_item, null: false, foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :created_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.integer :tax_year, null: false
      t.string :plan_digest, null: false
      t.string :review_reference, null: false
      t.jsonb :evidence, null: false
      t.datetime :created_at, null: false
    end
    execute <<~SQL
      CREATE FUNCTION prevent_fica_basis_proof_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'payroll_item_fica_basis_proofs are append-only';
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER fica_basis_proofs_append_only
      BEFORE UPDATE OR DELETE ON payroll_item_fica_basis_proofs
      FOR EACH ROW EXECUTE FUNCTION prevent_fica_basis_proof_mutation();
      CREATE TRIGGER fica_basis_proofs_no_truncate BEFORE TRUNCATE ON payroll_item_fica_basis_proofs
      FOR EACH STATEMENT EXECUTE FUNCTION prevent_fica_basis_proof_mutation();
    SQL
  end

  def down
    drop_table :payroll_item_fica_basis_proofs
    execute "DROP FUNCTION IF EXISTS prevent_fica_basis_proof_mutation()"
  end
end
