# frozen_string_literal: true

# The push of committed payroll to Cornerstone Tax (PayrollTaxSyncService) was
# removed. Its pay_periods columns stay for now because evidence checksums hash
# full PayPeriod attributes; this only stops new rows from claiming a pending
# sync and labels the columns as retired.
class RetirePayPeriodTaxSyncColumns < ActiveRecord::Migration[8.0]
  RETIRED = "Retired: Cornerstone Tax payroll push was removed; not read or written."

  def change
    change_column_default :pay_periods, :tax_sync_status, from: "pending", to: nil
    %i[tax_sync_status tax_sync_attempts tax_sync_last_error tax_synced_at tax_sync_idempotency_key].each do |column|
      change_column_comment :pay_periods, column, from: nil, to: RETIRED
    end
  end
end
