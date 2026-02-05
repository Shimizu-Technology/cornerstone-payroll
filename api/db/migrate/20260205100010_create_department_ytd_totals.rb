# frozen_string_literal: true

class CreateDepartmentYtdTotals < ActiveRecord::Migration[8.1]
  def change
    create_table :department_ytd_totals do |t|
      t.references :department, null: false, foreign_key: true
      t.integer :year, null: false

      # Pay totals
      t.decimal :gross_pay, precision: 16, scale: 2, default: 0
      t.decimal :net_pay, precision: 16, scale: 2, default: 0

      # Tax totals
      t.decimal :withholding_tax, precision: 16, scale: 2, default: 0
      t.decimal :social_security_tax, precision: 16, scale: 2, default: 0
      t.decimal :medicare_tax, precision: 16, scale: 2, default: 0

      # Employee count
      t.integer :total_employees, default: 0

      t.timestamps
    end

    add_index :department_ytd_totals, [ :department_id, :year ], unique: true
  end
end
