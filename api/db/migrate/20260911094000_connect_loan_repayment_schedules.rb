# frozen_string_literal: true

class ConnectLoanRepaymentSchedules < ActiveRecord::Migration[8.1]
  def change
    add_index :employee_payroll_fields, :employee_loan_id, unique: true,
      where: "employee_loan_id IS NOT NULL", name: "idx_employee_fields_unique_loan"
    add_index :employee_loans, [ :employee_id, :deduction_type_id ], unique: true,
      where: "deduction_type_id IS NOT NULL", name: "idx_employee_loans_unique_deduction"
    add_column :employee_loans, :first_deduction_date, :date
    add_reference :payroll_item_deductions, :employee_loan, foreign_key: true
    add_column :payroll_item_deductions, :loan_schedule_snapshot, :jsonb, default: {}, null: false
    add_reference :loan_transactions, :reverses_transaction, foreign_key: { to_table: :loan_transactions }, index: { unique: true }
  end
end
