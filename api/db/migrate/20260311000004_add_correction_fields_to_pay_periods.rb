# frozen_string_literal: true

# CPR-71: Add payroll-level correction lifecycle fields to pay_periods.
#
# Design intent:
#   - correction_status tracks whether this period is normal, voided, or a correction run.
#   - voided_* columns record the void event immutably on the period itself.
#   - source_pay_period_id: for correction runs, points back to the voided source period.
#   - superseded_by_id: for voided periods, points to the correction run that replaced them.
#
# All historical committed data is preserved; nothing is deleted.
class AddCorrectionFieldsToPayPeriods < ActiveRecord::Migration[8.1]
  def change
    # null = normal committed/draft/etc.
    # 'voided'     = this period was voided after commit
    # 'correction' = this period is a correction re-run created from a voided period
    add_column :pay_periods, :correction_status, :string

    # Who voided it and when/why
    add_column :pay_periods, :voided_at,     :datetime
    add_column :pay_periods, :voided_by_id,  :bigint
    add_column :pay_periods, :void_reason,   :text

    # Self-referential links for the correction chain
    # correction_run.source_pay_period_id → voided_period.id
    add_column :pay_periods, :source_pay_period_id, :bigint
    # voided_period.superseded_by_id → correction_run.id
    add_column :pay_periods, :superseded_by_id, :bigint

    add_index :pay_periods, :correction_status
    add_index :pay_periods, :source_pay_period_id
    add_index :pay_periods, :superseded_by_id
    add_index :pay_periods, :voided_by_id
  end
end
