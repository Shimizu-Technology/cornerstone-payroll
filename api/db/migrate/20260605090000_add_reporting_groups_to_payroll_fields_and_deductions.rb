# frozen_string_literal: true

class AddReportingGroupsToPayrollFieldsAndDeductions < ActiveRecord::Migration[8.1]
  def change
    add_column :deduction_types, :reporting_group, :string
    add_column :payroll_item_deductions, :reporting_group, :string
    add_column :payroll_field_definitions, :reporting_group, :string
    add_column :payroll_item_field_entries, :reporting_group, :string

    add_index :deduction_types, [ :company_id, :reporting_group ], name: "idx_deduction_types_company_reporting_group"
    add_index :payroll_item_deductions, :reporting_group, name: "idx_payroll_item_deductions_reporting_group"
    add_index :payroll_field_definitions, [ :company_id, :reporting_group ], name: "idx_payroll_fields_company_reporting_group"
    add_index :payroll_item_field_entries, :reporting_group, name: "idx_payroll_item_field_entries_reporting_group"
  end
end
