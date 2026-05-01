# frozen_string_literal: true

class SupportStandaloneNonEmployeeChecks < ActiveRecord::Migration[8.1]
  def change
    change_column_null :non_employee_checks, :pay_period_id, true

    add_column :non_employee_checks, :payment_period_type, :string, default: "none", null: false
    add_column :non_employee_checks, :tax_year, :integer
    add_column :non_employee_checks, :tax_quarter, :integer
    add_column :non_employee_checks, :tax_month, :integer
    add_column :non_employee_checks, :due_date, :date
    add_column :non_employee_checks, :payment_date, :date
    add_column :non_employee_checks, :confirmation_number, :string

    add_index :non_employee_checks, [ :company_id, :payment_period_type, :tax_year, :tax_quarter ],
      name: "idx_ne_checks_on_company_quarter"
    add_index :non_employee_checks, [ :company_id, :payment_period_type, :tax_year, :tax_month ],
      name: "idx_ne_checks_on_company_month"
    add_index :non_employee_checks, [ :company_id, :payment_date ],
      name: "idx_ne_checks_on_company_payment_date"
    add_check_constraint :non_employee_checks,
      "payment_period_type IN ('none', 'pay_period', 'month', 'quarter', 'year')",
      name: "non_employee_checks_payment_period_type_check"
    add_check_constraint :non_employee_checks,
      "tax_quarter IS NULL OR tax_quarter BETWEEN 1 AND 4",
      name: "non_employee_checks_tax_quarter_check"
    add_check_constraint :non_employee_checks,
      "tax_month IS NULL OR tax_month BETWEEN 1 AND 12",
      name: "non_employee_checks_tax_month_check"
  end
end
