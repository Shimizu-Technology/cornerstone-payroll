# frozen_string_literal: true

class CreatePayrollItemDeductions < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_item_deductions do |t|
      t.references :payroll_item, null: false, foreign_key: true
      t.references :deduction_type, null: false, foreign_key: true
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.string :category, null: false
      t.string :label, null: false
      t.timestamps
    end

    add_index :payroll_item_deductions,
              [:payroll_item_id, :deduction_type_id],
              unique: true,
              name: "idx_pi_deductions_on_pi_and_dt"
  end
end
