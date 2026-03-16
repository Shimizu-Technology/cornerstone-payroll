# frozen_string_literal: true

class AddCompanyScopedCheckNumberIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    if index_exists?(:payroll_items, :check_number, name: "index_payroll_items_on_check_number_unique")
      remove_index :payroll_items,
                   name: "index_payroll_items_on_check_number_unique",
                   algorithm: :concurrently
    end

    unless index_exists?(:payroll_items, [ :company_id, :check_number ], name: "index_payroll_items_on_company_check_number_unique")
      add_index :payroll_items, [ :company_id, :check_number ],
                unique: true,
                where: "check_number IS NOT NULL",
                name: "index_payroll_items_on_company_check_number_unique",
                algorithm: :concurrently
    end
  end

  def down
    if index_exists?(:payroll_items, [ :company_id, :check_number ], name: "index_payroll_items_on_company_check_number_unique")
      remove_index :payroll_items,
                   name: "index_payroll_items_on_company_check_number_unique",
                   algorithm: :concurrently
    end

    unless index_exists?(:payroll_items, :check_number, name: "index_payroll_items_on_check_number_unique")
      add_index :payroll_items, :check_number,
                unique: true,
                where: "check_number IS NOT NULL",
                name: "index_payroll_items_on_check_number_unique",
                algorithm: :concurrently
    end
  end
end
