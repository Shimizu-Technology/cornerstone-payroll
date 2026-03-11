# frozen_string_literal: true

# CPR-71: allow re-correction after voiding a committed correction run.
# Unique source index should ignore correction runs already marked voided.
class AdjustCorrectionSourceUniqueIndexForRevoids < ActiveRecord::Migration[8.1]
  OLD_INDEX = "idx_pay_periods_unique_source_correction_run"

  def change
    remove_index :pay_periods, name: OLD_INDEX if index_exists?(:pay_periods, name: OLD_INDEX)

    add_index :pay_periods,
      :source_pay_period_id,
      unique: true,
      where: "source_pay_period_id IS NOT NULL AND correction_status <> 'voided'",
      name: OLD_INDEX
  end
end
