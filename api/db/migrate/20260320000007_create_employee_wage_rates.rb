# frozen_string_literal: true

class CreateEmployeeWageRates < ActiveRecord::Migration[8.0]
  def change
    create_table :employee_wage_rates do |t|
      t.references :employee, null: false, foreign_key: true
      t.string :label, null: false
      t.decimal :rate, precision: 12, scale: 6
      t.boolean :is_primary, default: false, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end

    add_index :employee_wage_rates, [:employee_id, :label], unique: true
  end
end
