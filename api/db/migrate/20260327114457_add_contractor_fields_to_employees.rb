class AddContractorFieldsToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :business_name, :string
    add_column :employees, :contractor_ein, :string
    add_column :employees, :w9_on_file, :boolean, default: false, null: false
    add_column :employees, :contractor_type, :string, default: "individual"
  end
end
