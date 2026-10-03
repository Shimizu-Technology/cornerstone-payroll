class CreateDirectDepositPaymentConfirmations < ActiveRecord::Migration[8.0]
  def change
    create_table :direct_deposit_payment_confirmations do |t|
      t.references :payroll_item, null: false, foreign_key: true, index: { unique: true }
      t.references :user, null: false, foreign_key: true
      t.date :settled_on, null: false
      t.string :bank_reference, null: false
      t.text :note
      t.string :ip_address
      t.timestamps
    end

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION prevent_check_evidence_mutation()
          RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION '% records are append-only', TG_TABLE_NAME;
          END;
          $$ LANGUAGE plpgsql;

          CREATE TRIGGER direct_deposit_payment_confirmations_append_only
          BEFORE UPDATE OR DELETE ON direct_deposit_payment_confirmations
          FOR EACH ROW EXECUTE FUNCTION prevent_check_evidence_mutation();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER IF EXISTS direct_deposit_payment_confirmations_append_only ON direct_deposit_payment_confirmations"
      end
    end
  end
end
