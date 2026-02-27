# frozen_string_literal: true

class AddTaxSyncFieldsToPayPeriods < ActiveRecord::Migration[8.1]
  def change
    add_column :pay_periods, :tax_sync_status, :string, default: "pending"
    add_column :pay_periods, :tax_sync_attempts, :integer, default: 0, null: false
    add_column :pay_periods, :tax_sync_last_error, :text
    add_column :pay_periods, :tax_synced_at, :datetime
    add_column :pay_periods, :tax_sync_idempotency_key, :string

    add_index :pay_periods, :tax_sync_status
    add_index :pay_periods, :tax_sync_idempotency_key, unique: true
  end
end
