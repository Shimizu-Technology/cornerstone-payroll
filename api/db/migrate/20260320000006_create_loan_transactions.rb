# frozen_string_literal: true

class CreateLoanTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :loan_transactions do |t|
      t.references :employee_loan, null: false, foreign_key: true
      t.references :pay_period, foreign_key: true
      t.references :payroll_item, foreign_key: true
      t.string :transaction_type, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.decimal :balance_before, precision: 10, scale: 2, null: false
      t.decimal :balance_after, precision: 10, scale: 2, null: false
      t.date :transaction_date, null: false
      t.text :notes
      t.timestamps
    end

    add_index :loan_transactions, [:employee_loan_id, :pay_period_id],
              name: "idx_loan_txns_on_loan_and_pp"
    add_index :loan_transactions, :transaction_type
  end
end
