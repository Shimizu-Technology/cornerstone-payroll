class AddSalaryTypeToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :salary_type, :string, default: "annual", null: false
  end
end
