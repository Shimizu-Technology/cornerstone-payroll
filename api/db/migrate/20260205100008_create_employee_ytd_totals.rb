# frozen_string_literal: true

class CreateEmployeeYtdTotals < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_ytd_totals do |t|
      t.references :employee, null: false, foreign_key: true
      t.integer :year, null: false

      # Pay totals
      t.decimal :gross_pay, precision: 14, scale: 2, default: 0
      t.decimal :net_pay, precision: 14, scale: 2, default: 0

      # Tax totals
      t.decimal :withholding_tax, precision: 14, scale: 2, default: 0
      t.decimal :social_security_tax, precision: 14, scale: 2, default: 0
      t.decimal :medicare_tax, precision: 14, scale: 2, default: 0

      # Deduction totals
      t.decimal :retirement, precision: 14, scale: 2, default: 0
      t.decimal :roth_retirement, precision: 14, scale: 2, default: 0
      t.decimal :insurance, precision: 14, scale: 2, default: 0
      t.decimal :loans, precision: 14, scale: 2, default: 0

      # Other totals
      t.decimal :tips, precision: 14, scale: 2, default: 0
      t.decimal :bonus, precision: 14, scale: 2, default: 0
      t.decimal :overtime_pay, precision: 14, scale: 2, default: 0

      t.timestamps
    end

    add_index :employee_ytd_totals, [ :employee_id, :year ], unique: true
  end
end
