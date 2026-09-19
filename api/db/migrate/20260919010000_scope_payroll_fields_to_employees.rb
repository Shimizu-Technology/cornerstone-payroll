# frozen_string_literal: true

class ScopePayrollFieldsToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_reference :payroll_field_definitions, :owner_employee, foreign_key: { to_table: :employees }, index: true

    remove_index :payroll_field_definitions, name: "idx_payroll_fields_company_name"
    add_index :payroll_field_definitions, [ :company_id, :name ], unique: true,
      where: "owner_employee_id IS NULL", name: "idx_payroll_fields_company_name"
    add_index :payroll_field_definitions, [ :owner_employee_id, :name ], unique: true,
      where: "owner_employee_id IS NOT NULL", name: "idx_payroll_fields_employee_name"
  end
end
