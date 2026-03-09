class ChangePayRatePrecisionInPayrollItems < ActiveRecord::Migration[8.1]
  def change
    change_column :payroll_items, :pay_rate, :decimal, precision: 12, scale: 6
    change_column :employees, :pay_rate, :decimal, precision: 12, scale: 6
  end
end
