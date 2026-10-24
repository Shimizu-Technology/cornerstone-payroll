# frozen_string_literal: true

class AddLateHoursRecoveryState < ActiveRecord::Migration[8.1]
  def up
    add_column :time_tracking_late_hours_runs, :state, :string, null: false, default: 'pending'
    add_column :time_tracking_late_hours_runs, :resolution, :jsonb, null: false, default: {}
    add_column :time_tracking_late_hours_runs, :resolved_at, :datetime
    add_reference :time_tracking_late_hours_runs, :resolved_by, foreign_key: { to_table: :users }
    execute "UPDATE time_tracking_late_hours_runs SET state = 'applied' WHERE applied_at IS NOT NULL"
    execute "UPDATE time_tracking_late_hours_runs SET state = 'ambiguous' WHERE applied_at IS NULL"
    add_check_constraint :time_tracking_late_hours_runs,
      "state IN ('pending', 'ambiguous', 'reconciliation_required', 'applied', 'rejected', 'cancelled')",
      name: 'late_hours_recovery_state'
  end

  def down
    remove_check_constraint :time_tracking_late_hours_runs, name: 'late_hours_recovery_state'
    remove_reference :time_tracking_late_hours_runs, :resolved_by, foreign_key: { to_table: :users }
    remove_column :time_tracking_late_hours_runs, :resolved_at
    remove_column :time_tracking_late_hours_runs, :resolution
    remove_column :time_tracking_late_hours_runs, :state
  end
end
