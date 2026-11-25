# frozen_string_literal: true

# M4-9d: the demo early-access rule. An owner-approved, dated window during
# which named demo companies may turn the employee app on before database
# row-level security is enforced. Each row records who set it and when, and
# is never edited afterwards except to end it once.
class CreateEmployeeAppEarlyAccessWindows < ActiveRecord::Migration[8.1]
  def up
    create_table :employee_app_early_access_windows do |t|
      t.references :organization, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.bigint :company_ids, array: true, null: false
      t.date :expires_on, null: false
      t.string :reason, limit: 500, null: false
      t.references :set_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }, index: true
      t.datetime :ended_at
      t.references :ended_by, foreign_key: { to_table: :users, on_delete: :restrict }, index: true
      t.string :end_reason, limit: 500
      t.timestamps null: false

      t.index %i[organization_id created_at id], name: "idx_employee_app_early_access_windows_history"
      t.index :organization_id, unique: true, where: "ended_at IS NULL",
        name: "idx_employee_app_early_access_windows_one_open"
      t.check_constraint "cardinality(company_ids) BETWEEN 1 AND 2 AND array_position(company_ids, NULL) IS NULL",
        name: "employee_app_early_access_windows_company_ids_check"
      # created_at is stored in UTC; the window is counted in Guam business days.
      t.check_constraint "expires_on >= ((created_at AT TIME ZONE 'UTC') AT TIME ZONE 'Pacific/Guam')::date AND " \
        "expires_on <= ((created_at AT TIME ZONE 'UTC') AT TIME ZONE 'Pacific/Guam')::date + 31",
        name: "employee_app_early_access_windows_expiry_check"
      t.check_constraint "length(btrim(reason)) > 0", name: "employee_app_early_access_windows_reason_check"
      t.check_constraint "(ended_at IS NULL AND ended_by_id IS NULL AND end_reason IS NULL) OR " \
        "(ended_at IS NOT NULL AND ended_by_id IS NOT NULL AND length(btrim(end_reason)) > 0)",
        name: "employee_app_early_access_windows_end_shape_check"
    end

    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_employee_app_early_access_window() RETURNS trigger AS $$
      BEGIN
        IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
          OR NEW.company_ids IS DISTINCT FROM OLD.company_ids
          OR NEW.expires_on IS DISTINCT FROM OLD.expires_on
          OR NEW.reason IS DISTINCT FROM OLD.reason
          OR NEW.set_by_id IS DISTINCT FROM OLD.set_by_id
          OR NEW.created_at IS DISTINCT FROM OLD.created_at
          OR OLD.ended_at IS NOT NULL
        THEN
          RAISE EXCEPTION 'employee_app_early_access_windows rows can only be ended once; set a new window instead'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS employee_app_early_access_windows_immutable ON employee_app_early_access_windows;
      CREATE TRIGGER employee_app_early_access_windows_immutable
      BEFORE UPDATE ON employee_app_early_access_windows
      FOR EACH ROW
      EXECUTE FUNCTION protect_employee_app_early_access_window();

      CREATE OR REPLACE FUNCTION prevent_employee_app_early_access_window_delete() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'employee_app_early_access_windows rows are kept for the audit history'
          USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS employee_app_early_access_windows_no_delete ON employee_app_early_access_windows;
      CREATE TRIGGER employee_app_early_access_windows_no_delete
      BEFORE DELETE ON employee_app_early_access_windows
      FOR EACH ROW
      EXECUTE FUNCTION prevent_employee_app_early_access_window_delete();
    SQL
  end

  def down
    drop_table :employee_app_early_access_windows
    execute "DROP FUNCTION IF EXISTS protect_employee_app_early_access_window()"
    execute "DROP FUNCTION IF EXISTS prevent_employee_app_early_access_window_delete()"
  end
end
