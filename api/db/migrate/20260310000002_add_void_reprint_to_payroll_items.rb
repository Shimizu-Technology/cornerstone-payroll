# frozen_string_literal: true

class AddVoidReprintToPayrollItems < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_items, :voided, :boolean, default: false, null: false
    add_column :payroll_items, :voided_at, :datetime
    add_column :payroll_items, :voided_by_user_id, :bigint
    add_column :payroll_items, :void_reason, :string
    # Tracks which original check number this item is a reprint of
    add_column :payroll_items, :reprint_of_check_number, :string
    # How many times this check has been sent to the printer
    add_column :payroll_items, :check_print_count, :integer, default: 0, null: false

    add_index :payroll_items, :voided
    add_index :payroll_items, :reprint_of_check_number
    add_foreign_key :payroll_items, :users, column: :voided_by_user_id

    # Enforce uniqueness on check_number (null excluded — allows multiple unassigned items)
    # We use a partial unique index: only non-null check numbers must be unique
    add_index :payroll_items, :check_number, unique: true,
      where: "check_number IS NOT NULL",
      name: "index_payroll_items_on_check_number_unique"
  end
end
