# frozen_string_literal: true

class EnforcePayrollItemsCompanyIdNotNull < ActiveRecord::Migration[8.0]
  def up
    col = company_id_column
    return unless col
    return if col.null == false

    unless check_constraint_exists?(:payroll_items, name: "payroll_items_company_id_not_null")
      add_check_constraint :payroll_items,
                           "company_id IS NOT NULL",
                           name: "payroll_items_company_id_not_null",
                           validate: false
      validate_check_constraint :payroll_items, name: "payroll_items_company_id_not_null"
    end

    with_lock_timeout do
      change_column_null :payroll_items, :company_id, false
    end
  end

  def down
    col = company_id_column
    return unless col
    return if col.null

    with_lock_timeout do
      change_column_null :payroll_items, :company_id, true
    end
  end

  private

  def company_id_column
    connection.columns(:payroll_items).find { |column| column.name == "company_id" }
  end

  def with_lock_timeout
    execute "SET LOCAL lock_timeout = '5s'"
    yield
  end
end
