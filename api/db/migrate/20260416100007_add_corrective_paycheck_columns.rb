# frozen_string_literal: true

# Adds the schema bits needed for the per-employee corrective paycheck flow.
#
# A "corrective paycheck" is a single-employee fix to an already-committed
# pay period that should NOT void the entire period. Implementation:
#
#   - A new pay_period is created with cycle='supplemental' and
#     corrects_pay_period_id pointing back at the original. It has its own
#     pay_date (when the corrective check is issued), goes through the same
#     commit pipeline, and contributes to YTD/W-2/tax sync just like any
#     other reportable period.
#
#   - The single PayrollItem on the supplemental period stores DELTAS
#     (corrected_value - original_value) for gross/FIT/SS/Medicare/etc.,
#     plus correction_for_payroll_item_id pointing back at the original
#     item being corrected and a correction_reason for the audit trail.
#
# We deliberately do NOT reuse the existing source_pay_period_id /
# correction_status='correction' linkage from CPR-71's full-period
# void+redo flow, because (a) that linkage is unique-per-source and we
# need many corrections per period, and (b) supplementals are *not* a
# correction run that supersedes the original — the original stays alive
# and reportable.
class AddCorrectivePaycheckColumns < ActiveRecord::Migration[8.0]
  def change
    add_column :pay_periods, :cycle, :string, default: "regular", null: false
    add_index  :pay_periods, :cycle

    # No unique constraint: many supplementals per source are allowed.
    add_reference :pay_periods, :corrects_pay_period,
                  foreign_key: { to_table: :pay_periods },
                  null: true,
                  index: true

    add_reference :payroll_items, :correction_for_payroll_item,
                  foreign_key: { to_table: :payroll_items },
                  null: true,
                  index: true

    add_column :payroll_items, :correction_reason, :text

    # Defensive check constraint: cycle must be one of the known values.
    # PostgreSQL only — wrap in begin/rescue so non-PG envs (sqlite tests
    # if any) don't break.
    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          ALTER TABLE pay_periods
            ADD CONSTRAINT pay_periods_cycle_check
            CHECK (cycle IN ('regular', 'supplemental'))
        SQL
      end

      dir.down do
        execute <<~SQL.squish
          ALTER TABLE pay_periods
            DROP CONSTRAINT IF EXISTS pay_periods_cycle_check
        SQL
      end
    end
  end
end
