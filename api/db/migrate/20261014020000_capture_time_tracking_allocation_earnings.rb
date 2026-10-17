# frozen_string_literal: true

class CaptureTimeTrackingAllocationEarnings < ActiveRecord::Migration[8.1]
  def change
    # Existing immutable allocations retain empty captures; do not invent past
    # wage mapping decisions from today's employee profile.
    add_column :time_tracking_entry_allocations, :earning_snapshot, :jsonb, null: false, default: {}
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_source_earning_capture() RETURNS trigger AS $$
          BEGIN
            IF OLD.earning_snapshot <> '{}'::jsonb THEN
              RAISE EXCEPTION 'Captured source earning allocations are append-only';
            END IF;
            IF TG_OP = 'UPDATE' AND NEW.earning_snapshot IS DISTINCT FROM OLD.earning_snapshot THEN
              RAISE EXCEPTION 'Historical source earning captures cannot be invented';
            END IF;
            IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER source_earning_capture_immutable BEFORE UPDATE OR DELETE ON time_tracking_entry_allocations
            FOR EACH ROW EXECUTE FUNCTION protect_source_earning_capture();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER source_earning_capture_immutable ON time_tracking_entry_allocations"
        execute "DROP FUNCTION protect_source_earning_capture()"
      end
    end
  end
end
