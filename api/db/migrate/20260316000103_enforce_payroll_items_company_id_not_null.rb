# frozen_string_literal: true

class EnforcePayrollItemsCompanyIdNotNull < ActiveRecord::Migration[8.0]
  def up
    return if company_id_column.null == false

    unless check_constraint_exists?(:payroll_items, name: "payroll_items_company_id_not_null")
      add_check_constraint :payroll_items,
                           "company_id IS NOT NULL",
                           name: "payroll_items_company_id_not_null",
                           validate: false
      validate_check_constraint :payroll_items, name: "payroll_items_company_id_not_null"
    end

    change_column_null :payroll_items, :company_id, false
  end

  def down
    return if company_id_column.null

    change_column_null :payroll_items, :company_id, true
  end

  private

  def company_id_column
    connection.columns(:payroll_items).find { |column| column.name == "company_id" }
  end
end
