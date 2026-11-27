# frozen_string_literal: true

class CreateEmployeeVerificationItems < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"

    create_table :employee_verification_items do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }, index: false
      t.references :employee, null: false, index: false
      t.string :event_kind, null: false
      t.string :status, null: false, default: "pending_verification"
      t.boolean :affects_pay, null: false, default: true
      t.date :effective_on
      t.references :source_actor, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.string :source_record_type
      t.bigint :source_record_id
      t.jsonb :changed_fields, null: false, default: []
      t.jsonb :before_values, null: false, default: {}
      t.jsonb :after_values, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.references :verified_by, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.datetime :verified_at
      t.text :verification_note
      t.boolean :fixed_by_staff, null: false, default: false
      t.references :returned_by, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.datetime :returned_at
      t.text :return_note
      t.datetime :resubmitted_at
      t.bigint :superseded_by_id
      t.timestamps null: false

      t.index %i[id company_id], unique: true, name: "idx_employee_verification_items_tenant_key"
      t.index %i[company_id status created_at], name: "idx_employee_verification_items_company_status_created"
      t.index %i[company_id employee_id status], name: "idx_employee_verification_items_company_employee_status"
      t.index %i[company_id employee_id event_kind],
        where: "status IN ('pending_verification', 'returned_to_client')",
        name: "idx_employee_verification_items_open_by_kind"
      t.index :superseded_by_id,
        where: "superseded_by_id IS NOT NULL",
        name: "idx_employee_verification_items_superseded_by"

      t.check_constraint(
        "event_kind IN ('new_hire', 'compensation_change', 'w4_change', 'payment_method_change', " \
        "'identity_tax_change', 'contractor_tax_change', 'termination', 'rehire', 'profile_change')",
        name: "employee_verification_items_event_kind_check"
      )
      t.check_constraint(
        "status IN ('pending_verification', 'returned_to_client', 'verified', 'superseded')",
        name: "employee_verification_items_status_check"
      )
      t.check_constraint(
        "superseded_by_id IS NULL OR superseded_by_id <> id",
        name: "employee_verification_items_not_self_superseded_check"
      )
    end

    add_foreign_key :employee_verification_items, :employees,
      column: %i[employee_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_employee_verification_items_employee"
    add_foreign_key :employee_verification_items, :employee_verification_items,
      column: %i[superseded_by_id company_id], primary_key: %i[id company_id],
      on_delete: :restrict, name: "fk_employee_verification_items_superseded_by"

    stage_company_policy!
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    drop_table :employee_verification_items
  end

  private

  def stage_company_policy!
    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'employee_verification_items', NULL, NULL, false)"
    return unless connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'employee_account_links'::regclass")

    execute "ALTER TABLE employee_verification_items ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE employee_verification_items FORCE ROW LEVEL SECURITY"
  end
end
