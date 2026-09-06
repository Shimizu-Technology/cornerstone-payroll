# frozen_string_literal: true

class AddHistoricalPayrollFeatureGate < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :historical_payroll_enabled, :boolean, null: false, default: false
  end
end
