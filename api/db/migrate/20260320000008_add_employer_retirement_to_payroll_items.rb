# frozen_string_literal: true

class AddEmployerRetirementToPayrollItems < ActiveRecord::Migration[8.0]
  def change
    change_table :payroll_items, bulk: true do |t|
      t.decimal :employer_retirement_match, precision: 10, scale: 2, default: 0.0
      t.decimal :employer_roth_retirement_match, precision: 10, scale: 2, default: 0.0
    end
  end
end
