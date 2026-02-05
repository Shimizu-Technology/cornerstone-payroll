class CreateFilingStatusConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :filing_status_configs do |t|
      t.references :annual_tax_config, null: false, foreign_key: true
      t.string :filing_status, null: false  # single, married, head_of_household
      t.decimal :standard_deduction, precision: 12, scale: 2, null: false  # Annual amount

      t.timestamps
    end

    add_index :filing_status_configs, [:annual_tax_config_id, :filing_status], 
              unique: true, 
              name: 'idx_filing_status_configs_unique'
  end
end
