# frozen_string_literal: true

class AddVerifiedOpeningBalancesToEmployeeLoans < ActiveRecord::Migration[8.0]
  def up
    add_column :employee_loans, :opening_balance, :decimal, precision: 10, scale: 2
    add_column :employee_loans, :balance_as_of, :date
    add_column :employee_loans, :balance_source, :string
    add_column :employee_loans, :principal_amount_known, :boolean, default: true, null: false
    add_reference :employee_loans, :created_by, foreign_key: { to_table: :users, on_delete: :nullify }

    add_column :loan_transactions, :source, :string
    add_reference :loan_transactions, :recorded_by, foreign_key: { to_table: :users, on_delete: :nullify }

    execute <<~SQL
      UPDATE employee_loans
      SET opening_balance = original_amount,
          balance_as_of = COALESCE(start_date, created_at::date),
          balance_source = 'new_loan'
    SQL
    execute <<~SQL
      UPDATE loan_transactions
      SET source = CASE
        WHEN payroll_item_id IS NOT NULL THEN 'payroll'
        WHEN notes = 'Initial loan' THEN 'opening_balance'
        ELSE 'manual'
      END
    SQL

    change_column_null :employee_loans, :opening_balance, false
    change_column_null :employee_loans, :balance_as_of, false
    change_column_null :employee_loans, :balance_source, false
    change_column_null :loan_transactions, :source, false

    add_check_constraint :employee_loans,
      "balance_source IN ('new_loan', 'quickbooks', 'statement', 'employee_confirmation', 'other_verified')",
      name: "employee_loans_balance_source_check"
    add_check_constraint :loan_transactions,
      "source IN ('opening_balance', 'payroll', 'manual')",
      name: "loan_transactions_source_check"
  end

  def down
    remove_check_constraint :loan_transactions, name: "loan_transactions_source_check"
    remove_check_constraint :employee_loans, name: "employee_loans_balance_source_check"
    remove_reference :loan_transactions, :recorded_by, foreign_key: true
    remove_column :loan_transactions, :source
    remove_reference :employee_loans, :created_by, foreign_key: true
    remove_column :employee_loans, :principal_amount_known
    remove_column :employee_loans, :balance_source
    remove_column :employee_loans, :balance_as_of
    remove_column :employee_loans, :opening_balance
  end
end
