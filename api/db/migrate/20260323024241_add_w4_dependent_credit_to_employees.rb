class AddW4DependentCreditToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :w4_dependent_credit, :decimal, precision: 10, scale: 2, default: 0.0, null: false
  end
end
