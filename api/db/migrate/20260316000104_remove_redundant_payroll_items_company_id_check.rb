# frozen_string_literal: true

class RemoveRedundantPayrollItemsCompanyIdCheck < ActiveRecord::Migration[8.0]
  def up
    return unless check_constraint_exists?(:payroll_items, name: "payroll_items_company_id_not_null")

    remove_check_constraint :payroll_items, name: "payroll_items_company_id_not_null"
  end

  def down
    return if check_constraint_exists?(:payroll_items, name: "payroll_items_company_id_not_null")

    add_check_constraint :payroll_items,
                         "company_id IS NOT NULL",
                         name: "payroll_items_company_id_not_null",
                         validate: false
    validate_check_constraint :payroll_items, name: "payroll_items_company_id_not_null"
  end
end
