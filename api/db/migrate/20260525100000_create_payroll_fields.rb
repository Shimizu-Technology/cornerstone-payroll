# frozen_string_literal: true

class CreatePayrollFields < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_field_definitions do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.string :kind, null: false
      t.string :tax_treatment, null: false
      t.string :category, null: false, default: "other"
      t.string :amount_type, null: false, default: "fixed"
      t.decimal :default_amount, precision: 10, scale: 2
      t.decimal :default_percentage, precision: 8, scale: 4
      t.boolean :show_in_payroll_grid, null: false, default: true
      t.boolean :active, null: false, default: true
      t.integer :sort_order, null: false, default: 0
      t.string :payee_name
      t.string :reference_number

      t.timestamps
    end

    add_index :payroll_field_definitions, [ :company_id, :name ], unique: true, name: "idx_payroll_fields_company_name"
    add_index :payroll_field_definitions, [ :company_id, :active, :sort_order ], name: "idx_payroll_fields_company_active_order"

    create_table :employee_payroll_fields do |t|
      t.references :employee, null: false, foreign_key: true
      t.references :payroll_field_definition, null: false, foreign_key: true, index: { name: "idx_employee_payroll_fields_definition" }
      t.decimal :amount, precision: 10, scale: 2
      t.decimal :percentage, precision: 8, scale: 4
      t.boolean :active, null: false, default: true
      t.date :start_date
      t.date :end_date
      t.text :notes
      t.references :employee_loan, foreign_key: { on_delete: :nullify }

      t.timestamps
    end

    add_index :employee_payroll_fields, [ :employee_id, :payroll_field_definition_id ], unique: true, name: "idx_employee_payroll_fields_unique"
    add_index :employee_payroll_fields, [ :employee_id, :active ], name: "idx_employee_payroll_fields_employee_active"

    create_table :payroll_item_field_entries do |t|
      t.references :payroll_item, null: false, foreign_key: true, index: { name: "idx_payroll_item_field_entries_item" }
      t.references :payroll_field_definition, foreign_key: true, index: { name: "idx_payroll_item_field_entries_definition" }
      t.string :label, null: false
      t.string :kind, null: false
      t.string :tax_treatment, null: false
      t.string :category, null: false, default: "other"
      t.decimal :amount, precision: 10, scale: 2, null: false, default: 0
      t.string :source, null: false, default: "employee_default"
      t.boolean :employee_paid, null: false, default: true
      t.boolean :employer_paid, null: false, default: false
      t.boolean :active, null: false, default: true
      t.text :notes
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :payroll_item_field_entries, [ :payroll_item_id, :payroll_field_definition_id ], unique: true, name: "idx_payroll_item_field_entries_unique_definition"
    add_index :payroll_item_field_entries, [ :payroll_item_id, :tax_treatment ], name: "idx_payroll_item_field_entries_treatment"
  end
end
