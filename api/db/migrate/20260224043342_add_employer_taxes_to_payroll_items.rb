# frozen_string_literal: true

class AddEmployerTaxesToPayrollItems < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_items, :employer_social_security_tax, :decimal, precision: 10, scale: 2, default: 0.0, null: false
    add_column :payroll_items, :employer_medicare_tax, :decimal, precision: 10, scale: 2, default: 0.0, null: false
  end
end
