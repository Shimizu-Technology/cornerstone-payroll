# frozen_string_literal: true

class CreateTimeTrackingCategoryMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :time_tracking_category_mappings do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.string :source_category_key, null: false
      t.string :earning_label
      t.boolean :import_enabled, null: false, default: false
      t.boolean :historical_attribution, null: false, default: false
      t.jsonb :historical_employee_ids, null: false, default: []
      t.date :history_through_on
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.text :reason, null: false
      t.text :evidence, null: false
      t.timestamps
    end
    add_index :time_tracking_category_mappings, [:time_tracking_source_id, :source_category_key], unique: true, name: "idx_source_category_mapping"
  end
end
