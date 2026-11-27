# frozen_string_literal: true

class CreateCompanyJobRoles < ActiveRecord::Migration[8.1]
  def up
    create_table :company_job_roles do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :occupation_code
      t.boolean :active, default: true, null: false
      t.timestamps
      t.index %i[company_id name], unique: true
      t.index %i[id company_id], unique: true
    end
    add_reference :employees, :company_job_role
    add_foreign_key :employees, :company_job_roles, column: %i[company_job_role_id company_id],
      primary_key: %i[id company_id]

    execute File.read(Rails.root.join("db/rls_policies.sql"))
    execute "SELECT pg_temp.install_company_policy(current_schema(), 'company_job_roles', NULL, NULL, false)"
    if connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'employee_account_links'::regclass")
      execute "ALTER TABLE company_job_roles ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE company_job_roles FORCE ROW LEVEL SECURITY"
    end
  end

  def down
    remove_foreign_key :employees, :company_job_roles
    remove_reference :employees, :company_job_role
    drop_table :company_job_roles
  end
end
