# frozen_string_literal: true

class AddCalculationContextSnapshotToPayrollItems < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_items, :calculation_context_snapshot, :jsonb, null: false, default: {}
  end
end
