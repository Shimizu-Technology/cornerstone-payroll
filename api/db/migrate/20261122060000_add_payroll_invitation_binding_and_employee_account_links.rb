# frozen_string_literal: true

class AddPayrollInvitationBindingAndEmployeeAccountLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :invite_nonce_digest, :string
    add_column :users, :invite_nonce_expires_at, :datetime

    add_index :companies, [ :id, :payroll_environment ], unique: true, name: "idx_companies_payroll_environment_key"

    create_table :employee_account_links do |t|
      t.references :user, null: true, foreign_key: true
      t.references :company, null: false
      t.references :employee, null: false
      t.string :payroll_environment, null: false, default: "live"
      t.string :status, null: false, default: "invited"
      t.string :invite_token_digest
      t.datetime :invite_expires_at
      t.references :invited_by, foreign_key: { to_table: :users }
      t.datetime :activated_at
      t.datetime :former_at
      t.datetime :former_access_until
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.string :revoked_reason
      t.timestamps

      t.index :invite_token_digest, unique: true
      t.index :employee_id, unique: true, where: "status IN ('invited', 'active')", name: "idx_employee_account_links_open"
      t.check_constraint "status IN ('invited', 'active', 'former', 'revoked')", name: "employee_account_links_status_check"
      t.check_constraint "payroll_environment = 'live'", name: "employee_account_links_live_only"
    end

    add_foreign_key :employee_account_links, :employees, column: [ :employee_id, :company_id ],
      primary_key: [ :id, :company_id ], name: "fk_employee_account_links_employee"
    add_foreign_key :employee_account_links, :companies, column: [ :company_id, :payroll_environment ],
      primary_key: [ :id, :payroll_environment ], name: "fk_employee_account_links_live_company"
  end
end
