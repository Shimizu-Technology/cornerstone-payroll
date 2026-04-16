class AddCustomEarningsAndCheckDateToPayrollItems < ActiveRecord::Migration[7.1]
  def change
    add_column :payroll_items, :custom_earnings, :jsonb, default: []
    add_column :payroll_items, :check_date, :date, null: true
    add_column :payroll_items, :check_memo, :string, null: true
  end
end
