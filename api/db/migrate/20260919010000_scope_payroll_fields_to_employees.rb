# frozen_string_literal: true

class ScopePayrollFieldsToEmployees < ActiveRecord::Migration[8.1]
  def up
    add_reference :payroll_field_definitions, :owner_employee, foreign_key: { to_table: :employees }, index: true

    remove_index :payroll_field_definitions, name: "idx_payroll_fields_company_name"
    add_index :payroll_field_definitions, [ :company_id, :name ], unique: true,
      where: "owner_employee_id IS NULL", name: "idx_payroll_fields_company_name"
    add_index :payroll_field_definitions, [ :owner_employee_id, :name ], unique: true,
      where: "owner_employee_id IS NOT NULL", name: "idx_payroll_fields_employee_name"
  end

  def down
    if select_value("SELECT 1 FROM payroll_field_definitions WHERE owner_employee_id IS NOT NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Employee-only payroll fields must be migrated before rollback"
    end

    remove_index :payroll_field_definitions, name: "idx_payroll_fields_employee_name"
    remove_index :payroll_field_definitions, name: "idx_payroll_fields_company_name"
    add_index :payroll_field_definitions, [ :company_id, :name ], unique: true, name: "idx_payroll_fields_company_name"
    remove_reference :payroll_field_definitions, :owner_employee, foreign_key: { to_table: :employees }, index: true
  end
end
