# frozen_string_literal: true

class ProtectPlatformOwnerAndEnrichAuditHistory < ActiveRecord::Migration[8.0]
  PRIMARY_PLATFORM_OWNER_EMAIL = "shimizutechnology@gmail.com"

  def up
    add_column :users, :platform_owner, :boolean, null: false, default: false
    add_index :users, :platform_owner, unique: true, where: "platform_owner = TRUE", name: "index_users_on_single_platform_owner"
    add_check_constraint :users,
                         "NOT platform_owner OR (role = 5 AND active = TRUE AND LOWER(email) = '#{PRIMARY_PLATFORM_OWNER_EMAIL}')",
                         name: "users_platform_owner_identity"

    execute <<~SQL.squish
      UPDATE users
      SET platform_owner = TRUE, role = 5, active = TRUE
      WHERE LOWER(email) = '#{PRIMARY_PLATFORM_OWNER_EMAIL}'
    SQL

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

      CREATE TRIGGER protect_primary_platform_owner_delete
      BEFORE DELETE ON users
      FOR EACH ROW
      EXECUTE FUNCTION prevent_primary_platform_owner_delete();
    SQL

    execute <<~SQL.squish
      UPDATE audit_logs
      SET subject_name = NULLIF(TRIM(CONCAT_WS(' ', employees.first_name, employees.middle_name, employees.last_name)), '')
      FROM employees
      WHERE LOWER(audit_logs.record_type) IN ('employee', 'employees')
        AND audit_logs.record_id = employees.id
        AND (audit_logs.subject_name IS NULL OR audit_logs.subject_name = '')
    SQL

    execute <<~SQL.squish
      UPDATE audit_logs
      SET subject_name = COALESCE(NULLIF(users.name, ''), users.email)
      FROM users
      WHERE LOWER(audit_logs.record_type) IN ('user', 'users')
        AND audit_logs.record_id = users.id
        AND (audit_logs.subject_name IS NULL OR audit_logs.subject_name = '')
    SQL

    execute <<~SQL.squish
      UPDATE audit_logs
      SET subject_name = CONCAT(TO_CHAR(pay_periods.start_date, 'Mon DD, YYYY'), ' – ', TO_CHAR(pay_periods.end_date, 'Mon DD, YYYY'))
      FROM pay_periods
      WHERE LOWER(audit_logs.record_type) IN ('payperiod', 'pay_period', 'pay_periods')
        AND audit_logs.record_id = pay_periods.id
        AND (audit_logs.subject_name IS NULL OR audit_logs.subject_name = '')
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS protect_primary_platform_owner_delete ON users"
    execute "DROP FUNCTION IF EXISTS prevent_primary_platform_owner_delete()"
    remove_check_constraint :users, name: "users_platform_owner_identity"
    remove_index :users, name: "index_users_on_single_platform_owner"
    remove_column :users, :platform_owner
  end
end
