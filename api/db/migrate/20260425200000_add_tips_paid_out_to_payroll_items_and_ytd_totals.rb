class AddTipsPaidOutToPayrollItemsAndYtdTotals < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :tips_paid_out, :decimal, precision: 10, scale: 2, default: 0.0, null: false
    add_column :employee_ytd_totals, :tips_paid_out, :decimal, precision: 14, scale: 2, default: 0.0, null: false
  end
end
