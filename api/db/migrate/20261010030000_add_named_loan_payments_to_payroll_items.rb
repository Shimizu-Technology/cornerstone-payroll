# frozen_string_literal: true

class AddNamedLoanPaymentsToPayrollItems < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :named_loan_payments, :jsonb, null: false, default: {}
    add_check_constraint :payroll_items, "jsonb_typeof(named_loan_payments) = 'object'", name: "payroll_items_named_loan_payments_object"
  end
end
