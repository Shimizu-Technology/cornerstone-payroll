# frozen_string_literal: true

class AddInitialTimeTrackingLockRolloutSelections < ActiveRecord::Migration[8.1]
  def up
    create_table :time_tracking_lock_rollout_selections do |t|
      t.references :time_tracking_source, null: false, foreign_key: true, index: { unique: true }
      t.date :starts_on, null: false
      t.string :actor, null: false
      t.text :reason, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :time_tracking_lock_rollout_selections,
      "EXTRACT(DAY FROM starts_on) IN (1, 16) AND length(trim(actor)) > 0 AND length(trim(reason)) >= 10",
      name: "initial_time_tracking_lock_rollout_valid"
    execute <<~SQL
      CREATE FUNCTION protect_initial_time_tracking_lock_rollout() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          RAISE EXCEPTION 'initial payroll lock rollout selections are immutable';
        END IF;
        PERFORM 1 FROM time_tracking_sources WHERE id = NEW.time_tracking_source_id AND source_type = 'aire_services' FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'initial payroll rollout selection requires an AIRE source';
        END IF;
        IF NEW.starts_on <= (SELECT cutoff_enforcement_starts_on FROM time_tracking_sources WHERE id = NEW.time_tracking_source_id) THEN
          RAISE EXCEPTION 'initial payroll rollout selection must be later than the legacy boundary';
        END IF;
        IF EXISTS (SELECT 1 FROM aire_payroll_calendar_periods WHERE time_tracking_source_id = NEW.time_tracking_source_id)
          OR EXISTS (SELECT 1 FROM aire_payroll_calendar_publications publications JOIN aire_payroll_calendar_periods periods ON periods.id = publications.aire_payroll_calendar_period_id WHERE periods.time_tracking_source_id = NEW.time_tracking_source_id)
          OR EXISTS (SELECT 1 FROM aire_verified_history_rollout_receipts WHERE time_tracking_source_id = NEW.time_tracking_source_id)
          OR EXISTS (SELECT 1 FROM time_tracking_imports WHERE time_tracking_source_id = NEW.time_tracking_source_id)
          OR EXISTS (SELECT 1 FROM audit_logs WHERE record_type = 'TimeTrackingSource' AND record_id = NEW.time_tracking_source_id
            AND action = 'time_tracking_source#lock_rollout_gate_passed') THEN
          RAISE EXCEPTION 'initial payroll rollout selection requires an unused, ungated source';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER initial_time_tracking_lock_rollout_immutable
        BEFORE INSERT OR UPDATE OR DELETE ON time_tracking_lock_rollout_selections
        FOR EACH ROW EXECUTE FUNCTION protect_initial_time_tracking_lock_rollout();
      CREATE TRIGGER initial_time_tracking_lock_rollout_prevent_truncate
        BEFORE TRUNCATE ON time_tracking_lock_rollout_selections
        FOR EACH STATEMENT EXECUTE FUNCTION protect_initial_time_tracking_lock_rollout();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve the initial rollout decision"
  end
end
