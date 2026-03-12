# frozen_string_literal: true

# CPR-71: Durable audit table for every payroll correction action.
#
# This table is append-only. Records are never updated or deleted.
# It captures the full financial context at the time of each action,
# so the audit trail remains accurate even if related records change.
#
# action_type values:
#   'void_initiated'          – a committed pay period was voided
#   'correction_run_created'  – a new draft correction period was created from a void
#   'correction_run_committed'– a correction run was committed (final lock)
class CreatePayPeriodCorrectionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :pay_period_correction_events do |t|
      # Mandatory classification
      t.string  :action_type,  null: false

      # Primary period this event is about (the source being voided / corrected)
      t.bigint  :pay_period_id, null: false

      # For correction_run_created / correction_run_committed: the new period
      t.bigint  :resulting_pay_period_id

      # Who did it (FK kept soft so records survive user deletion)
      t.bigint  :actor_id
      t.string  :actor_name   # denormalized — stays accurate even if user is renamed

      t.bigint  :company_id,  null: false

      # Mandatory human-readable reason
      t.text    :reason, null: false

      # Immutable financial snapshot at the moment of the action
      # Keys: gross_pay, net_pay, employee_count, total_withholding,
      #       total_social_security, total_medicare,
      #       total_employer_ss, total_employer_medicare
      t.jsonb   :financial_snapshot, default: {}, null: false

      # Arbitrary additional context
      t.jsonb   :metadata, default: {}, null: false

      t.timestamps null: false
    end

    add_index :pay_period_correction_events, :pay_period_id
    add_index :pay_period_correction_events, :resulting_pay_period_id
    add_index :pay_period_correction_events, :company_id
    add_index :pay_period_correction_events, :action_type
    add_index :pay_period_correction_events, :actor_id
    add_index :pay_period_correction_events,
              [ :pay_period_id, :action_type ],
              name: "idx_ppce_pay_period_action"
    add_index :pay_period_correction_events, :created_at
  end
end
