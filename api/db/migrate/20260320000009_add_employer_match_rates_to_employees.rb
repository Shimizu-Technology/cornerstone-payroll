# frozen_string_literal: true

class AddEmployerMatchRatesToEmployees < ActiveRecord::Migration[8.0]
  def change
    change_table :employees, bulk: true do |t|
      t.decimal :employer_retirement_match_rate, precision: 5, scale: 4, default: 0.0
      t.decimal :employer_roth_match_rate, precision: 5, scale: 4, default: 0.0
    end
  end
end
