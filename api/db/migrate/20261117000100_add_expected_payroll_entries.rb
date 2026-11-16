# frozen_string_literal: true

class AddExpectedPayrollEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_standing_changes, :label, :string
    add_column :payroll_standing_changes, :help_text, :text
    add_column :payroll_standing_changes, :required, :boolean, null: false, default: false
    add_column :payroll_standing_changes, :allow_none, :boolean, null: false, default: true
    add_column :companies, :regular_pay_lookback, :integer, null: false, default: 4
    add_column :companies, :regular_pay_threshold, :integer, null: false, default: 3
    add_check_constraint :companies, "regular_pay_threshold > 0 AND regular_pay_threshold <= regular_pay_lookback AND regular_pay_lookback <= 24", name: "regular_pay_rule"
    create_table :payroll_entry_resolutions do |t|
      t.references :pay_period, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :payroll_standing_change, foreign_key: true
      t.string :note, limit: 500
      t.timestamps
    end
    add_index :payroll_entry_resolutions, [ :pay_period_id, :payroll_standing_change_id ], unique: true, where: "payroll_standing_change_id IS NOT NULL", name: "idx_entry_resolution_field"
    add_index :payroll_entry_resolutions, [ :pay_period_id, :employee_id ], unique: true, where: "payroll_standing_change_id IS NULL", name: "idx_entry_resolution_regular"
  end
end
