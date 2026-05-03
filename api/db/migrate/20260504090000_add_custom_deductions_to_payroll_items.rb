# frozen_string_literal: true

class AddCustomDeductionsToPayrollItems < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_items, :custom_deductions, :jsonb, default: [], null: false
  end
end
