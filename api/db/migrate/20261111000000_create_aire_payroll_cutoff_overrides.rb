# frozen_string_literal: true

# Append-only history of admin changes to an AIRE pay period's lock time. The
# newest row is the period's current lock time; a reset row returns it to the
# policy cutoff. Each row keeps who, why, when and the previous value.
class CreateAirePayrollCutoffOverrides < ActiveRecord::Migration[8.1]
  def up
    create_table :aire_payroll_cutoff_overrides do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :pay_period, null: false, foreign_key: { on_delete: :restrict }
      t.references :aire_payroll_calendar_period, null: false, foreign_key: { on_delete: :restrict },
                   index: { name: "idx_aire_cutoff_overrides_calendar_period" }
      t.uuid :override_id, null: false
      t.string :action, null: false
      t.datetime :cutoff_at, null: false
      t.datetime :previous_cutoff_at, null: false
      t.datetime :policy_cutoff_at, null: false
      t.text :reason, null: false
      t.string :requested_via, null: false
      t.references :set_by, foreign_key: { to_table: :users, on_delete: :restrict }
      t.jsonb :source_actor
      t.uuid :request_id
      t.datetime :created_at, null: false
    end

    add_index :aire_payroll_cutoff_overrides, :override_id, unique: true
    add_index :aire_payroll_cutoff_overrides, :request_id, unique: true, where: "request_id IS NOT NULL"
    add_index :aire_payroll_cutoff_overrides, [ :pay_period_id, :created_at, :id ],
              name: "idx_aire_cutoff_overrides_pay_period_newest"
    add_check_constraint :aire_payroll_cutoff_overrides, "action IN ('lock_now', 'change', 'reset')",
                         name: "aire_cutoff_overrides_action"
    add_check_constraint :aire_payroll_cutoff_overrides, "requested_via IN ('cornerstone_payroll', 'aire_services')",
                         name: "aire_cutoff_overrides_requested_via"
    add_check_constraint :aire_payroll_cutoff_overrides, "length(btrim(reason)) > 0 AND length(reason) <= 500",
                         name: "aire_cutoff_overrides_reason"
    add_check_constraint :aire_payroll_cutoff_overrides,
                         "(requested_via = 'cornerstone_payroll' AND set_by_id IS NOT NULL) OR " \
                         "(requested_via = 'aire_services' AND source_actor IS NOT NULL AND jsonb_typeof(source_actor) = 'object')",
                         name: "aire_cutoff_overrides_actor"
    add_check_constraint :aire_payroll_cutoff_overrides, "action <> 'reset' OR cutoff_at = policy_cutoff_at",
                         name: "aire_cutoff_overrides_reset_policy"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_aire_payroll_cutoff_override()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'AIRE payroll cutoff overrides are append-only';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER aire_payroll_cutoff_overrides_append_only
      BEFORE UPDATE OR DELETE ON aire_payroll_cutoff_overrides
      FOR EACH ROW EXECUTE FUNCTION protect_aire_payroll_cutoff_override();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS aire_payroll_cutoff_overrides_append_only ON aire_payroll_cutoff_overrides"
    execute "DROP FUNCTION IF EXISTS protect_aire_payroll_cutoff_override()"
    drop_table :aire_payroll_cutoff_overrides
  end
end
