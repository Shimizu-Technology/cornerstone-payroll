class CreateAnnualTaxConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :annual_tax_configs do |t|
      t.integer :tax_year, null: false
      t.decimal :ss_wage_base, precision: 12, scale: 2, null: false
      t.decimal :ss_rate, precision: 6, scale: 5, default: 0.062, null: false
      t.decimal :medicare_rate, precision: 6, scale: 5, default: 0.0145, null: false
      t.decimal :additional_medicare_rate, precision: 6, scale: 5, default: 0.009, null: false
      t.decimal :additional_medicare_threshold, precision: 12, scale: 2, default: 200_000, null: false
      t.boolean :is_active, default: false, null: false
      t.bigint :created_by_id, null: true  # User ID (FK added when users table exists)
      t.bigint :updated_by_id, null: true  # User ID (FK added when users table exists)

      t.timestamps
    end

    add_index :annual_tax_configs, :tax_year, unique: true
    add_index :annual_tax_configs, :is_active
  end
end
