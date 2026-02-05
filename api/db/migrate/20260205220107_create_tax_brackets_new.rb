class CreateTaxBracketsNew < ActiveRecord::Migration[8.1]
  def change
    create_table :tax_brackets do |t|
      t.references :filing_status_config, null: false, foreign_key: true
      t.integer :bracket_order, null: false  # 1-7
      t.decimal :min_income, precision: 12, scale: 2, null: false  # Annual amount
      t.decimal :max_income, precision: 12, scale: 2, null: true   # null = infinity
      t.decimal :rate, precision: 6, scale: 5, null: false         # e.g., 0.10, 0.12

      t.timestamps
    end

    add_index :tax_brackets, [:filing_status_config_id, :bracket_order], 
              unique: true, 
              name: 'idx_tax_brackets_order_unique'
  end
end
