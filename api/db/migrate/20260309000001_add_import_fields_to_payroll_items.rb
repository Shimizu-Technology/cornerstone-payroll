# frozen_string_literal: true

class AddImportFieldsToPayrollItems < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_items, :tips, :decimal, precision: 10, scale: 2, default: 0.0
    add_column :payroll_items, :loan_deduction, :decimal, precision: 10, scale: 2, default: 0.0
    add_column :payroll_items, :tip_pool, :string
    add_column :payroll_items, :import_source, :string
  end
end
