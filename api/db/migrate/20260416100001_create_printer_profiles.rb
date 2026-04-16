class CreatePrinterProfiles < ActiveRecord::Migration[7.1]
  def change
    create_table :printer_profiles do |t|
      t.references :company, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.text :notes
      t.string :check_stock_type, default: "top_check", null: false
      t.decimal :check_offset_x, precision: 5, scale: 3, default: 0.0, null: false
      t.decimal :check_offset_y, precision: 5, scale: 3, default: 0.0, null: false
      t.jsonb :check_layout_config, default: {}, null: false
      t.boolean :is_default, default: false, null: false
      t.timestamps
    end

    add_index :printer_profiles, [:company_id, :name], unique: true
  end
end
