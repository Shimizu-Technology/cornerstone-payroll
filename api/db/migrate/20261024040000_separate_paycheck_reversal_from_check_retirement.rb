# frozen_string_literal: true

class SeparatePaycheckReversalFromCheckRetirement < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :payroll_reversed_at, :datetime
    add_column :payroll_items, :payroll_reversal_reason, :text
    add_reference :payroll_items, :payroll_reversed_by, foreign_key: { to_table: :users }
    add_check_constraint :payroll_items,
      "(payroll_reversed_at IS NULL AND payroll_reversed_by_id IS NULL AND payroll_reversal_reason IS NULL) OR " \
      "(payroll_reversed_at IS NOT NULL AND payroll_reversed_by_id IS NOT NULL AND payroll_reversal_reason IS NOT NULL)",
      name: "check_payroll_item_reversal_fields"
  end
end
