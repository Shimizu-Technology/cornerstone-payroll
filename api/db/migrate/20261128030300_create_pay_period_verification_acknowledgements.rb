# frozen_string_literal: true

class CreatePayPeriodVerificationAcknowledgements < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"

    create_table :pay_period_verification_acknowledgements do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :pay_period, null: false, index: false
      t.references :employee_verification_item, null: false, index: false
      t.references :employee, null: false, index: false
      t.references :acknowledged_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }, index: true
      t.datetime :acknowledged_at, null: false
      t.string :item_status_snapshot, null: false
      t.datetime :item_updated_at_snapshot, null: false
      t.timestamps null: false

      t.index %i[pay_period_id employee_verification_item_id],
        unique: true,
        name: "idx_pp_verification_acks_period_item"
      t.index %i[company_id employee_verification_item_id],
        name: "idx_pp_verification_acks_company_item"
      t.index %i[company_id employee_id],
        name: "idx_pp_verification_acks_company_employee"

      t.check_constraint(
        "item_status_snapshot IN ('pending_verification', 'returned_to_client')",
        name: "pay_period_verification_acks_status_snapshot_check"
      )
    end

    add_foreign_key :pay_period_verification_acknowledgements, :pay_periods,
      column: %i[pay_period_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_pp_verification_acks_pay_period"
    add_foreign_key :pay_period_verification_acknowledgements, :employee_verification_items,
      column: %i[employee_verification_item_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_pp_verification_acks_item"
    add_foreign_key :pay_period_verification_acknowledgements, :employees,
      column: %i[employee_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_pp_verification_acks_employee"

    stage_company_policy!
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    drop_table :pay_period_verification_acknowledgements
  end

  private

  def stage_company_policy!
    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'pay_period_verification_acknowledgements', NULL, NULL, false)"
    return unless connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'employee_account_links'::regclass")

    execute "ALTER TABLE pay_period_verification_acknowledgements ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE pay_period_verification_acknowledgements FORCE ROW LEVEL SECURITY"
  end
end
