# frozen_string_literal: true

class ScopeCheckNumberUniquenessToCompany < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_column :payroll_items, :company_id, :bigint

    execute <<~SQL.squish
      UPDATE payroll_items
      SET company_id = pay_periods.company_id
      FROM pay_periods
      WHERE payroll_items.pay_period_id = pay_periods.id
        AND payroll_items.company_id IS NULL
    SQL

    change_column_null :payroll_items, :company_id, false
    add_foreign_key :payroll_items, :companies, on_delete: :restrict
    add_index :payroll_items, :company_id, algorithm: :concurrently

    remove_index :payroll_items, name: "index_payroll_items_on_check_number_unique"
    add_index :payroll_items, [ :company_id, :check_number ],
              unique: true,
              where: "check_number IS NOT NULL",
              name: "index_payroll_items_on_company_check_number_unique",
              algorithm: :concurrently
  end

  def down
    remove_index :payroll_items, name: "index_payroll_items_on_company_check_number_unique"
    add_index :payroll_items, :check_number,
              unique: true,
              where: "check_number IS NOT NULL",
              name: "index_payroll_items_on_check_number_unique",
              algorithm: :concurrently

    remove_index :payroll_items, :company_id
    remove_foreign_key :payroll_items, :companies
    remove_column :payroll_items, :company_id
  end
end
