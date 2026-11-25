# frozen_string_literal: true

class CreateViewAsGrants < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :view_as_allowed, :boolean, default: false, null: false

    create_table :view_as_grants do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :staff_user_id, null: false
      t.bigint :target_user_id
      t.bigint :target_employee_id
      t.string :mode, default: "view_only", null: false
      t.string :reason, limit: 500, null: false
      t.string :token_digest, null: false, index: { unique: true }
      t.datetime :expires_at, null: false
      t.datetime :ended_at
      t.timestamps null: false

      t.check_constraint "num_nonnulls(target_user_id, target_employee_id) = 1", name: "view_as_grants_one_target"
      t.check_constraint "mode = 'view_only'", name: "view_as_grants_view_only"
      t.check_constraint "expires_at > created_at AND expires_at <= created_at + interval '30 minutes'",
        name: "view_as_grants_max_lifetime"
    end

    # Keep the grant identifier in the audit even after workspace cleanup.
    add_column :audit_logs, :real_user_id, :bigint
    add_column :audit_logs, :view_as_grant_id, :bigint
    add_index :audit_logs, %i[company_id created_at id], where: "action = 'view_as#started'",
      name: "idx_audit_logs_support_access"

    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'view_as_grants', NULL, NULL, false)"

    # Preserve the tenant enforcement phase of the employee surface.
    if connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'employee_account_links'::regclass")
      execute "ALTER TABLE view_as_grants ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE view_as_grants FORCE ROW LEVEL SECURITY"
    end
  end

  def down
    remove_index :audit_logs, name: "idx_audit_logs_support_access"
    remove_column :audit_logs, :view_as_grant_id
    remove_column :audit_logs, :real_user_id
    drop_table :view_as_grants
    remove_column :users, :view_as_allowed
  end
end
