class AddCheckLayoutConfigToCompanies < ActiveRecord::Migration[8.0]
  def change
    add_column :companies, :check_layout_config, :jsonb, default: {}, null: false
  end
end
