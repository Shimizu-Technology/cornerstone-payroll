# frozen_string_literal: true

class CreatePayrollItems < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_items do |t|
      t.references :pay_period, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true

      # Hours and pay info (snapshot from employee at time of payroll)
      t.string :employment_type, null: false # hourly, salary
      t.decimal :pay_rate, precision: 10, scale: 2, null: false

      # Hours worked
      t.decimal :hours_worked, precision: 8, scale: 2, default: 0
      t.decimal :overtime_hours, precision: 8, scale: 2, default: 0
      t.decimal :holiday_hours, precision: 8, scale: 2, default: 0
      t.decimal :pto_hours, precision: 8, scale: 2, default: 0

      # Additional pay
      t.decimal :reported_tips, precision: 10, scale: 2, default: 0
      t.decimal :bonus, precision: 10, scale: 2, default: 0

      # Calculated pay
      t.decimal :gross_pay, precision: 12, scale: 2, default: 0
      t.decimal :net_pay, precision: 12, scale: 2, default: 0

      # Taxes withheld
      t.decimal :withholding_tax, precision: 10, scale: 2, default: 0 # Guam Territorial Income Tax
      t.decimal :social_security_tax, precision: 10, scale: 2, default: 0
      t.decimal :medicare_tax, precision: 10, scale: 2, default: 0
      t.decimal :additional_withholding, precision: 10, scale: 2, default: 0

      # Deductions
      t.decimal :retirement_payment, precision: 10, scale: 2, default: 0
      t.decimal :roth_retirement_payment, precision: 10, scale: 2, default: 0
      t.decimal :loan_payment, precision: 10, scale: 2, default: 0
      t.decimal :insurance_payment, precision: 10, scale: 2, default: 0

      # Totals
      t.decimal :total_deductions, precision: 12, scale: 2, default: 0
      t.decimal :total_additions, precision: 12, scale: 2, default: 0

      # YTD totals (snapshot at time of payroll)
      t.decimal :ytd_gross, precision: 14, scale: 2, default: 0
      t.decimal :ytd_net, precision: 14, scale: 2, default: 0
      t.decimal :ytd_withholding_tax, precision: 14, scale: 2, default: 0
      t.decimal :ytd_social_security_tax, precision: 14, scale: 2, default: 0
      t.decimal :ytd_medicare_tax, precision: 14, scale: 2, default: 0
      t.decimal :ytd_retirement, precision: 14, scale: 2, default: 0
      t.decimal :ytd_roth_retirement, precision: 14, scale: 2, default: 0

      # Flexible custom columns (JSON for additional deductions/additions)
      t.jsonb :custom_columns_data, default: {}

      # Check printing
      t.string :check_number
      t.datetime :check_printed_at

      t.timestamps
    end

    add_index :payroll_items, [ :pay_period_id, :employee_id ], unique: true
    add_index :payroll_items, :check_number
  end
end
