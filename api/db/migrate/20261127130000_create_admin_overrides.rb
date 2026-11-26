# frozen_string_literal: true

class CreateAdminOverrides < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_column :pay_periods, :rollback_review_required, :boolean, default: false, null: false
    create_table :admin_overrides do |t|
      t.references :company, null: false
      t.references :actor, null: false
      t.references :real_user
      t.references :subject, polymorphic: true, null: false
      t.string :action, null: false
      t.text :reason, null: false
      t.jsonb :before_snapshot, null: false
      t.jsonb :after_snapshot, null: false
      t.jsonb :preflight_result, null: false
      t.boolean :self_override, null: false, default: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :admin_overrides, :companies, validate: false
    add_foreign_key :admin_overrides, :users, column: :actor_id, validate: false
    add_foreign_key :admin_overrides, :users, column: :real_user_id, validate: false
    add_check_constraint :admin_overrides, "char_length(btrim(reason)) BETWEEN 10 AND 1000",
      name: "admin_overrides_reason_length", validate: false
    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'admin_overrides')"
    execute <<~SQL
      CREATE OR REPLACE FUNCTION reject_admin_override_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'admin_overrides is append-only';
      END;
      $$;
      CREATE TRIGGER admin_overrides_append_only BEFORE UPDATE OR DELETE ON admin_overrides
        FOR EACH ROW EXECUTE FUNCTION reject_admin_override_mutation();
      CREATE TRIGGER admin_overrides_no_truncate BEFORE TRUNCATE ON admin_overrides
        FOR EACH STATEMENT EXECUTE FUNCTION reject_admin_override_mutation();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Admin override evidence must be retained"
  end
end
