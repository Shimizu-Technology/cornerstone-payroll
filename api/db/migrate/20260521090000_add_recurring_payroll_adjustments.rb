# frozen_string_literal: true

class AddRecurringPayrollAdjustments < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :default_payroll_adjustments, :jsonb, null: false, default: []
    add_column :payroll_items, :payroll_adjustments, :jsonb, null: false, default: []
  end
end
