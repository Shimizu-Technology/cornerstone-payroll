# frozen_string_literal: true

# Saved starting points for the client profitability report, and how pay is
# dated (docs/CLIENT_PROFITABILITY.md). Defaults match today's behavior.
class AddReportDefaultsToClientProfitabilitySettings < ActiveRecord::Migration[8.1]
  def change
    change_table :client_profitability_settings, bulk: true do |t|
      t.boolean :default_cost_pending, null: false, default: false
      t.boolean :default_spread_overhead, null: false, default: false
      t.string :default_period, null: false, default: "month"
      t.string :cost_basis, null: false, default: "pay_date"
    end
    add_check_constraint :client_profitability_settings, "default_period IN ('month', 'quarter', 'custom')",
                         name: "client_profitability_default_period_valid"
    add_check_constraint :client_profitability_settings, "cost_basis IN ('pay_date', 'work_period')",
                         name: "client_profitability_cost_basis_valid"
  end
end
