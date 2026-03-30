class AddAutoCreateFitCheckToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :auto_create_fit_check, :boolean, default: false, null: false
  end
end
