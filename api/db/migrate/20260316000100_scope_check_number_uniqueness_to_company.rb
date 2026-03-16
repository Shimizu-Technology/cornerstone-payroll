# frozen_string_literal: true

class ScopeCheckNumberUniquenessToCompany < ActiveRecord::Migration[8.0]
  def up
    add_column :payroll_items, :company_id, :bigint

    execute <<~SQL.squish
      UPDATE payroll_items
      SET company_id = pay_periods.company_id
      FROM pay_periods
      WHERE payroll_items.pay_period_id = pay_periods.id
        AND payroll_items.company_id IS NULL
    SQL

    add_foreign_key :payroll_items, :companies, on_delete: :restrict, validate: false
    validate_foreign_key :payroll_items, :companies

    add_check_constraint :payroll_items,
                         "company_id IS NOT NULL",
                         name: "payroll_items_company_id_not_null",
                         validate: false
    validate_check_constraint :payroll_items, name: "payroll_items_company_id_not_null"
  end

  def down
    remove_check_constraint :payroll_items, name: "payroll_items_company_id_not_null"
    remove_foreign_key :payroll_items, :companies
    remove_column :payroll_items, :company_id
  end
end
