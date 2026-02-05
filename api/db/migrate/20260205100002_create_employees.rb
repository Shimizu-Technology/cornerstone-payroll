# frozen_string_literal: true

class CreateEmployees < ActiveRecord::Migration[8.1]
  def change
    create_table :employees do |t|
      t.references :company, null: false, foreign_key: true
      t.references :department, foreign_key: true

      # Personal information
      t.string :first_name, null: false
      t.string :middle_name
      t.string :last_name, null: false
      t.string :ssn_encrypted # Encrypted via Active Record Encryption
      t.date :date_of_birth

      # Employment information
      t.date :hire_date
      t.date :termination_date
      t.string :employment_type, null: false, default: "hourly" # hourly, salary
      t.decimal :pay_rate, precision: 10, scale: 2, null: false
      t.string :pay_frequency, default: "biweekly" # biweekly, weekly, semimonthly, monthly
      t.string :status, default: "active" # active, inactive, terminated

      # Tax information
      t.string :filing_status, default: "single" # single, married, married_separate, head_of_household
      t.integer :allowances, default: 0
      t.decimal :additional_withholding, precision: 10, scale: 2, default: 0

      # Retirement
      t.decimal :retirement_rate, precision: 5, scale: 4, default: 0 # e.g., 0.04 for 4%
      t.decimal :roth_retirement_rate, precision: 5, scale: 4, default: 0

      # Address
      t.string :address_line1
      t.string :address_line2
      t.string :city
      t.string :state
      t.string :zip

      # Contact
      t.string :email
      t.string :phone

      # Bank info (for future direct deposit - encrypted)
      t.string :bank_routing_number_encrypted
      t.string :bank_account_number_encrypted

      t.timestamps
    end

    add_index :employees, [ :company_id, :last_name, :first_name ]
    add_index :employees, :status
    add_index :employees, :employment_type
  end
end
