# frozen_string_literal: true

class CreateEmployeeDeductions < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_deductions do |t|
      t.references :employee, null: false, foreign_key: true
      t.references :deduction_type, null: false, foreign_key: true
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.boolean :is_percentage, default: false
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :employee_deductions, [ :employee_id, :deduction_type_id ], unique: true, name: "idx_employee_deductions_unique"
  end
end
