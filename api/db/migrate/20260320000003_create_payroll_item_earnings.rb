# frozen_string_literal: true

class CreatePayrollItemEarnings < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_item_earnings do |t|
      t.references :payroll_item, null: false, foreign_key: true
      t.string :category, null: false
      t.string :label, null: false
      t.decimal :hours, precision: 8, scale: 2, default: 0.0
      t.decimal :rate, precision: 12, scale: 6
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.timestamps
    end

    add_index :payroll_item_earnings,
              [:payroll_item_id, :category, :label],
              unique: true,
              name: "idx_pi_earnings_on_pi_cat_label"
  end
end
