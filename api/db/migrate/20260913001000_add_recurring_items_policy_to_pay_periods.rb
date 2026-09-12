# frozen_string_literal: true

class AddRecurringItemsPolicyToPayPeriods < ActiveRecord::Migration[8.0]
  def change
    add_column :pay_periods, :includes_recurring_items, :boolean, null: false, default: true
  end
end
