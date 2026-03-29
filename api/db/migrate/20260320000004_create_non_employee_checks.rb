# frozen_string_literal: true

class CreateNonEmployeeChecks < ActiveRecord::Migration[8.0]
  def change
    create_table :non_employee_checks do |t|
      t.references :pay_period, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.string :check_number
      t.string :payable_to, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.string :check_type, null: false
      t.string :memo
      t.text :description
      t.string :reference_number
      t.integer :print_count, default: 0, null: false
      t.datetime :printed_at
      t.boolean :voided, default: false, null: false
      t.string :void_reason
      t.datetime :voided_at
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :non_employee_checks,
              [:company_id, :check_number],
              unique: true,
              where: "check_number IS NOT NULL",
              name: "idx_ne_checks_on_company_check_num"
    add_index :non_employee_checks, :check_type
  end
end
