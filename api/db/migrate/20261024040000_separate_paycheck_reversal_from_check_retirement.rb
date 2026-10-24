# frozen_string_literal: true

class SeparatePaycheckReversalFromCheckRetirement < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :payroll_reversed_at, :datetime
    add_column :payroll_items, :payroll_reversal_reason, :text
    add_reference :payroll_items, :payroll_reversed_by, foreign_key: { to_table: :users }
  end
end
