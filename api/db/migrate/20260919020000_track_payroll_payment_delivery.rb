# frozen_string_literal: true

class TrackPayrollPaymentDelivery < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :payment_delivery_method, :string
    add_column :payroll_items, :payment_delivery_method, :string

    add_check_constraint :employees,
      "payment_delivery_method IS NULL OR payment_delivery_method IN ('paper_check', 'direct_deposit')",
      name: "employees_payment_delivery_method_check"
    add_check_constraint :payroll_items,
      "payment_delivery_method IS NULL OR payment_delivery_method IN ('paper_check', 'direct_deposit')",
      name: "payroll_items_payment_delivery_method_check"
    add_check_constraint :payroll_items,
      "payment_delivery_method IS DISTINCT FROM 'direct_deposit' OR check_number IS NULL",
      name: "payroll_items_direct_deposit_no_check_number"
  end
end
