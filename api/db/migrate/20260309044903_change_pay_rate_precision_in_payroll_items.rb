class ChangePayRatePrecisionInPayrollItems < ActiveRecord::Migration[8.1]
  def change
    reversible do |dir|
      dir.up do
        change_column :payroll_items, :pay_rate, :decimal, precision: 12, scale: 6
        change_column :employees, :pay_rate, :decimal, precision: 12, scale: 6
      end

      dir.down do
        change_column :payroll_items, :pay_rate, :decimal, precision: 10, scale: 2
        change_column :employees, :pay_rate, :decimal, precision: 10, scale: 2
      end
    end
  end
end
