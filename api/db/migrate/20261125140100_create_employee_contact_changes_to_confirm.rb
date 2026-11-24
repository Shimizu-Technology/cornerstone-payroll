# frozen_string_literal: true

class CreateEmployeeContactChangesToConfirm < ActiveRecord::Migration[8.1]
  def up
    create_table :employee_contact_changes_to_confirm do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.references :employee, null: false, index: false
      t.references :changed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :confirmed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :confirmed_at
      t.string :change_kind, null: false
      t.jsonb :before_values, null: false, default: {}
      t.jsonb :after_values, null: false, default: {}
      t.timestamps

      t.index %i[company_id confirmed_at id], name: "idx_contact_changes_confirmation"
      t.index %i[employee_id company_id], name: "idx_contact_changes_employee"
      t.check_constraint "change_kind IN ('contact', 'address')", name: "employee_contact_changes_kind_check"
    end

    add_foreign_key :employee_contact_changes_to_confirm, :employees, column: %i[employee_id company_id],
      primary_key: %i[id company_id], on_delete: :cascade, name: "fk_contact_changes_employee"

    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'employee_contact_changes_to_confirm', NULL, NULL, false)"
  end

  def down
    drop_table :employee_contact_changes_to_confirm
  end
end
