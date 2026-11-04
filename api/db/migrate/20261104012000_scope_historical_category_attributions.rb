# frozen_string_literal: true

class ScopeHistoricalCategoryAttributions < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_category_mappings, :historical_run_limits, :jsonb, default: {}, null: false
  end
end
