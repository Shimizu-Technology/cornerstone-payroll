class AddW4StepFieldsToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :w4_step2_multiple_jobs, :boolean, default: false, null: false
    add_column :employees, :w4_step4a_other_income, :decimal, precision: 10, scale: 2, default: 0.0, null: false
    add_column :employees, :w4_step4b_deductions, :decimal, precision: 10, scale: 2, default: 0.0, null: false
  end
end
