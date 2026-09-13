# frozen_string_literal: true

class CreateCheckReconciliationEvents < ActiveRecord::Migration[8.0]
  def up
    add_column :companies, :require_distinct_check_print_confirmer, :boolean, null: false, default: false

    add_column :check_events, :effective_on, :date
    add_column :check_events, :evidence_type, :string
    add_column :check_events, :evidence_reference, :string
    add_column :check_events, :details, :jsonb, null: false, default: {}
    # Check operations are performed in Guam. Rails stores timestamps in UTC,
    # so preserve the operator's local calendar date during the one-time backfill.
    execute <<~SQL
      UPDATE check_events
      SET effective_on = (created_at AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific/Guam')::date
      WHERE effective_on IS NULL
    SQL
    change_column_null :check_events, :effective_on, false
    remove_foreign_key :check_events, :users
    add_foreign_key :check_events, :users, on_delete: :restrict

    create_table :check_reconciliation_events do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: true, foreign_key: { on_delete: :restrict }
      t.references :payroll_item, null: true, foreign_key: { on_delete: :restrict }
      t.references :non_employee_check, null: true, foreign_key: { on_delete: :restrict }
      t.references :recorded_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.string :event_type, null: false
      t.string :check_number, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :effective_on, null: false
      t.string :evidence_type
      t.string :evidence_reference
      t.text :reason
      t.string :idempotency_key, null: false
      t.timestamps
    end

    add_index :check_reconciliation_events,
              [ :company_id, :idempotency_key ],
              unique: true,
              name: "idx_check_reconciliation_events_idempotency"
    add_index :check_reconciliation_events,
              [ :payroll_item_id, :check_number, :created_at ],
              name: "idx_check_reconciliation_events_payroll_instrument"
    add_index :check_reconciliation_events,
              [ :non_employee_check_id, :check_number, :created_at ],
              name: "idx_check_reconciliation_events_non_employee_instrument"
    add_check_constraint :check_reconciliation_events,
                         "((payroll_item_id IS NOT NULL)::integer + (non_employee_check_id IS NOT NULL)::integer) = 1",
                         name: "check_reconciliation_events_one_source"
    add_check_constraint :check_reconciliation_events,
                         "amount > 0",
                         name: "check_reconciliation_events_positive_amount"
    add_check_constraint :check_reconciliation_events,
                         "event_type IN ('cleared', 'clearing_reversed', 'replacement_required')",
                         name: "check_reconciliation_events_event_type"
    add_check_constraint :check_reconciliation_events,
                         "evidence_type IS NULL OR evidence_type IN ('bank_statement', 'bank_portal', 'accountant_review', 'payee_confirmation', 'other')",
                         name: "check_reconciliation_events_evidence_type"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_check_evidence_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION '% records are append-only', TG_TABLE_NAME;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER check_events_append_only
      BEFORE UPDATE OR DELETE ON check_events
      FOR EACH ROW EXECUTE FUNCTION prevent_check_evidence_mutation();

      CREATE TRIGGER check_reconciliation_events_append_only
      BEFORE UPDATE OR DELETE ON check_reconciliation_events
      FOR EACH ROW EXECUTE FUNCTION prevent_check_evidence_mutation();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS check_reconciliation_events_append_only ON check_reconciliation_events"
    execute "DROP TRIGGER IF EXISTS check_events_append_only ON check_events"
    execute "DROP FUNCTION IF EXISTS prevent_check_evidence_mutation()"

    drop_table :check_reconciliation_events

    remove_foreign_key :check_events, :users
    add_foreign_key :check_events, :users, on_delete: :nullify
    remove_column :check_events, :details
    remove_column :check_events, :evidence_reference
    remove_column :check_events, :evidence_type
    remove_column :check_events, :effective_on
    remove_column :companies, :require_distinct_check_print_confirmer
  end
end
