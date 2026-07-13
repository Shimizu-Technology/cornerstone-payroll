# frozen_string_literal: true

class ExpandPayRatePrecision < ActiveRecord::Migration[8.1]
  def up
    change_column :employees, :pay_rate, :decimal, precision: 18, scale: 6, null: false
    change_column :payroll_items, :pay_rate, :decimal, precision: 18, scale: 6, null: false
  end

  def down
    change_column :payroll_items, :pay_rate, :decimal, precision: 12, scale: 6, null: false
    change_column :employees, :pay_rate, :decimal, precision: 12, scale: 6, null: false
  end
end
