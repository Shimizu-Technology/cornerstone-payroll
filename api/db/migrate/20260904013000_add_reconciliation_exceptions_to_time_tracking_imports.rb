# frozen_string_literal: true

class AddReconciliationExceptionsToTimeTrackingImports < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_imports, :reconciliation_exceptions, :jsonb, null: false, default: []
  end
end
