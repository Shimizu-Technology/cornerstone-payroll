# frozen_string_literal: true

class CreateEmployeeLoans < ActiveRecord::Migration[8.0]
  def change
    create_table :employee_loans do |t|
      t.references :employee, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.references :deduction_type, foreign_key: true
      t.string :name, null: false
      t.decimal :original_amount, precision: 10, scale: 2, null: false
      t.decimal :current_balance, precision: 10, scale: 2, null: false, default: 0.0
      t.decimal :payment_amount, precision: 10, scale: 2
      t.date :start_date
      t.date :paid_off_date
      t.string :status, null: false, default: "active"
      t.text :notes
      t.timestamps
    end

    add_index :employee_loans, [:employee_id, :status]
    add_index :employee_loans, [:company_id, :status]
  end
end
