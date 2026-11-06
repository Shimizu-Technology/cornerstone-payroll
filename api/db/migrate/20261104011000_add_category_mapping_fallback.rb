# frozen_string_literal: true

class AddCategoryMappingFallback < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_category_mappings, :fallback_earning_label, :string
  end
end
