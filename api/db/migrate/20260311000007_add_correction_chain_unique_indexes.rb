# frozen_string_literal: true

# CPR-71: DB-level uniqueness constraints for correction-chain invariants.
class AddCorrectionChainUniqueIndexes < ActiveRecord::Migration[8.1]
  def change
    # A correction run points to exactly one source; each source may have at most one correction run.
    add_index :pay_periods,
      :source_pay_period_id,
      unique: true,
      where: "source_pay_period_id IS NOT NULL",
      name: "idx_pay_periods_unique_source_correction_run" unless index_exists?(:pay_periods, :source_pay_period_id, unique: true, name: "idx_pay_periods_unique_source_correction_run")

    # A voided/source period may be superseded by at most one correction run.
    add_index :pay_periods,
      :superseded_by_id,
      unique: true,
      where: "superseded_by_id IS NOT NULL",
      name: "idx_pay_periods_unique_superseded_by" unless index_exists?(:pay_periods, :superseded_by_id, unique: true, name: "idx_pay_periods_unique_superseded_by")
  end
end
