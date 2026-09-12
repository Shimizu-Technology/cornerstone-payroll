# frozen_string_literal: true

class AddTrackingModesToEmployeeLoans < ActiveRecord::Migration[8.1]
  def up
    add_column :employee_loans, :tracking_mode, :string, null: false, default: "balance_tracked"
    add_column :employee_loans, :stopped_at, :datetime
    add_reference :employee_loans, :stopped_by, foreign_key: { to_table: :users, on_delete: :nullify }

    change_column_null :employee_loans, :original_amount, true
    change_column_null :employee_loans, :current_balance, true
    change_column_null :employee_loans, :opening_balance, true
    change_column_null :employee_loans, :balance_as_of, true
    change_column_null :employee_loans, :balance_source, true
    change_column_null :loan_transactions, :balance_before, true
    change_column_null :loan_transactions, :balance_after, true

    add_check_constraint :employee_loans,
      "tracking_mode IN ('balance_tracked', 'recurring_no_balance')",
      name: "employee_loans_tracking_mode_check"
    add_check_constraint :employee_loans,
      "status IN ('active', 'paid_off', 'suspended', 'stopped')",
      name: "employee_loans_status_check"
    add_check_constraint :employee_loans,
      <<~SQL.squish,
        (tracking_mode = 'balance_tracked'
          AND original_amount IS NOT NULL AND original_amount > 0
          AND opening_balance IS NOT NULL AND opening_balance > 0
          AND current_balance IS NOT NULL AND current_balance >= 0
          AND balance_as_of IS NOT NULL AND balance_source IS NOT NULL
          AND status <> 'stopped')
        OR
        (tracking_mode = 'recurring_no_balance'
          AND original_amount IS NULL AND opening_balance IS NULL AND current_balance IS NULL
          AND balance_as_of IS NULL AND balance_source IS NULL
          AND principal_amount_known = FALSE
          AND status <> 'paid_off')
      SQL
      name: "employee_loans_tracking_shape"
    add_check_constraint :employee_loans,
      "(status = 'stopped' AND stopped_at IS NOT NULL) OR (status <> 'stopped' AND stopped_at IS NULL)",
      name: "employee_loans_stopped_shape"
    add_check_constraint :loan_transactions,
      "(balance_before IS NULL AND balance_after IS NULL) OR (balance_before IS NOT NULL AND balance_after IS NOT NULL)",
      name: "loan_transactions_balance_pair"
    add_index :loan_transactions, [ :employee_loan_id, :payroll_item_id ], unique: true,
      where: "source = 'payroll' AND transaction_type = 'payment' AND payroll_item_id IS NOT NULL",
      name: "idx_loan_txns_unique_payroll_payment"
  end

  def down
    recurring_count = select_value("SELECT COUNT(*) FROM employee_loans WHERE tracking_mode = 'recurring_no_balance'").to_i
    if recurring_count.positive?
      raise ActiveRecord::IrreversibleMigration,
        "Recurring deductions without balances cannot be represented by the prior employee_loans schema"
    end

    execute <<~SQL
      UPDATE employee_loans
      SET status = 'suspended', stopped_at = NULL, stopped_by_id = NULL
      WHERE status = 'stopped'
    SQL

    remove_index :loan_transactions, name: "idx_loan_txns_unique_payroll_payment"
    remove_check_constraint :loan_transactions, name: "loan_transactions_balance_pair"
    remove_check_constraint :employee_loans, name: "employee_loans_stopped_shape"
    remove_check_constraint :employee_loans, name: "employee_loans_tracking_shape"
    remove_check_constraint :employee_loans, name: "employee_loans_status_check"
    remove_check_constraint :employee_loans, name: "employee_loans_tracking_mode_check"

    change_column_null :loan_transactions, :balance_after, false
    change_column_null :loan_transactions, :balance_before, false
    change_column_null :employee_loans, :balance_source, false
    change_column_null :employee_loans, :balance_as_of, false
    change_column_null :employee_loans, :opening_balance, false
    change_column_null :employee_loans, :current_balance, false
    change_column_null :employee_loans, :original_amount, false

    remove_reference :employee_loans, :stopped_by, foreign_key: { to_table: :users }
    remove_column :employee_loans, :stopped_at
    remove_column :employee_loans, :tracking_mode
  end
end
