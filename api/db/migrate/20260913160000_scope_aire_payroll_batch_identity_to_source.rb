# frozen_string_literal: true

class ScopeAirePayrollBatchIdentityToSource < ActiveRecord::Migration[8.1]
  def up
    add_reference :aire_payroll_events,
                  :time_tracking_source,
                  null: true,
                  foreign_key: { on_delete: :restrict },
                  index: { name: "idx_aire_payroll_events_source" }

    execute <<~SQL.squish
      UPDATE aire_payroll_events AS event
      SET time_tracking_source_id = period.time_tracking_source_id
      FROM aire_payroll_calendar_periods AS period
      WHERE event.aire_payroll_calendar_period_id = period.id
    SQL
    change_column_null :aire_payroll_events, :time_tracking_source_id, false

    remove_index :aire_payroll_events, name: "idx_aire_payroll_events_batch_id"
    add_index :aire_payroll_events,
              [ :time_tracking_source_id, :payroll_batch_id ],
              unique: true,
              name: "idx_aire_payroll_events_source_batch"
    add_index :aire_payroll_calendar_periods,
              [ :id, :time_tracking_source_id ],
              unique: true,
              name: "idx_aire_calendar_periods_source_key"
    add_foreign_key :aire_payroll_events,
                    :aire_payroll_calendar_periods,
                    column: [ :aire_payroll_calendar_period_id, :time_tracking_source_id ],
                    primary_key: [ :id, :time_tracking_source_id ],
                    name: "fk_aire_payroll_events_period_source"
  end

  def down
    duplicate_batch_id = connection.select_value(<<~SQL.squish)
      SELECT payroll_batch_id
      FROM aire_payroll_events
      GROUP BY payroll_batch_id
      HAVING COUNT(*) > 1
      LIMIT 1
    SQL
    if duplicate_batch_id
      raise ActiveRecord::IrreversibleMigration,
            "Source-scoped payroll batch IDs cannot be restored to global uniqueness"
    end

    remove_foreign_key :aire_payroll_events,
                       name: "fk_aire_payroll_events_period_source"
    remove_index :aire_payroll_calendar_periods,
                 name: "idx_aire_calendar_periods_source_key"
    remove_index :aire_payroll_events,
                 name: "idx_aire_payroll_events_source_batch"
    add_index :aire_payroll_events,
              :payroll_batch_id,
              unique: true,
              name: "idx_aire_payroll_events_batch_id"
    remove_reference :aire_payroll_events,
                     :time_tracking_source,
                     foreign_key: true,
                     index: { name: "idx_aire_payroll_events_source" }
  end
end
