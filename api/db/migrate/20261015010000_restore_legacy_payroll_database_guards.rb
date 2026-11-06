# frozen_string_literal: true

# Populated databases can record these historical migrations as applied while
# missing their SQL guards (Ruby schema dumps do not retain functions/triggers).
# Repair only the two guards; never replay historical owner/audit data changes.
class RestoreLegacyPayrollDatabaseGuards < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_primary_platform_owner_delete()
      RETURNS trigger AS $$
      BEGIN
        IF OLD.platform_owner = TRUE THEN
          RAISE EXCEPTION 'The primary platform owner cannot be deleted';
        END IF;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS protect_primary_platform_owner_delete ON users;
      CREATE TRIGGER protect_primary_platform_owner_delete
      BEFORE DELETE ON users
      FOR EACH ROW
      EXECUTE FUNCTION prevent_primary_platform_owner_delete();

      CREATE OR REPLACE FUNCTION prevent_pay_period_parallel_run_clear()
      RETURNS trigger AS $$
      BEGIN
        IF OLD.parallel_run = TRUE AND NEW.parallel_run = FALSE THEN
          RAISE EXCEPTION 'parallel_run cannot be cleared after a payroll is used for comparison'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS pay_periods_parallel_run_immutable ON pay_periods;
      CREATE TRIGGER pay_periods_parallel_run_immutable
      BEFORE UPDATE OF parallel_run ON pay_periods
      FOR EACH ROW
      EXECUTE FUNCTION prevent_pay_period_parallel_run_clear();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain primary owner and parallel payroll database protection"
  end
end
