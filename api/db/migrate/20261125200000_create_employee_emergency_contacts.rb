# frozen_string_literal: true

class CreateEmployeeEmergencyContacts < ActiveRecord::Migration[8.1]
  def up
    create_table :employee_emergency_contacts do |t|
      t.references :company, null: false, foreign_key: true, index: false
      t.references :employee, null: false, index: false
      t.string :name, null: false
      t.string :relationship
      t.string :phone, null: false
      t.datetime :deleted_at
      t.timestamps

      t.index %i[company_id employee_id id], name: "idx_emergency_contacts_employee"
    end

    add_foreign_key :employee_emergency_contacts, :employees, column: %i[employee_id company_id],
      primary_key: %i[id company_id], on_delete: :cascade, name: "fk_emergency_contacts_employee"

    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'employee_emergency_contacts', NULL, NULL, false)"
  end

  def down
    drop_table :employee_emergency_contacts
  end
end
