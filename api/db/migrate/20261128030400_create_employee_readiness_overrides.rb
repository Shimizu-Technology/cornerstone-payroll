# frozen_string_literal: true

class CreateEmployeeReadinessOverrides < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"

    create_table :employee_readiness_overrides do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :employee, null: false, index: false
      t.references :pay_period, index: false
      t.date :expires_on
      t.jsonb :missing_items_snapshot, null: false, default: []
      t.boolean :default_w4_acknowledged, null: false, default: false
      t.bigint :default_w4_election_id
      t.text :reason, null: false
      t.references :granted_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }, index: true
      t.datetime :granted_at, null: false
      t.references :revoked_by, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.datetime :revoked_at
      t.text :revoke_reason
      t.references :admin_override, null: false, index: false
      t.timestamps null: false

      t.index %i[company_id employee_id],
        where: "revoked_at IS NULL",
        name: "idx_employee_readiness_overrides_active"
      t.index %i[employee_id pay_period_id],
        unique: true,
        where: "revoked_at IS NULL AND pay_period_id IS NOT NULL",
        name: "idx_employee_readiness_overrides_active_period"
      t.index %i[company_id admin_override_id],
        name: "idx_employee_readiness_overrides_company_admin_override"
      t.index :default_w4_election_id,
        where: "default_w4_election_id IS NOT NULL",
        name: "idx_employee_readiness_overrides_w4_election"

      t.check_constraint(
        "pay_period_id IS NOT NULL OR expires_on IS NOT NULL",
        name: "employee_readiness_overrides_scope_check"
      )
      t.check_constraint(
        "char_length(btrim(reason)) >= 10 AND char_length(btrim(reason)) <= 1000",
        name: "employee_readiness_overrides_reason_length_check"
      )
    end

    add_foreign_key :employee_readiness_overrides, :employees,
      column: %i[employee_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_employee_readiness_overrides_employee"
    add_foreign_key :employee_readiness_overrides, :pay_periods,
      column: %i[pay_period_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_employee_readiness_overrides_pay_period"
    add_foreign_key :employee_readiness_overrides, :employee_w4_elections,
      column: %i[default_w4_election_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_employee_readiness_overrides_w4_election"
    add_foreign_key :employee_readiness_overrides, :admin_overrides,
      column: %i[admin_override_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_employee_readiness_overrides_admin_override"

    stage_company_policy!
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    drop_table :employee_readiness_overrides
  end

  private

  def stage_company_policy!
    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'employee_readiness_overrides', NULL, NULL, false)"
    return unless connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'employee_account_links'::regclass")

    execute "ALTER TABLE employee_readiness_overrides ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE employee_readiness_overrides FORCE ROW LEVEL SECURITY"
  end
end
