# frozen_string_literal: true

class CreateDeductionTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :deduction_types do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false # e.g., "Health Insurance", "401k"
      t.string :category, null: false # pre_tax, post_tax
      t.decimal :default_amount, precision: 10, scale: 2
      t.boolean :is_percentage, default: false
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :deduction_types, [ :company_id, :name ], unique: true
    add_index :deduction_types, :category
  end
end
