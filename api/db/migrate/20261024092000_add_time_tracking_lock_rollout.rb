# frozen_string_literal: true

class AddTimeTrackingLockRollout < ActiveRecord::Migration[8.1]
  def up
    add_column :time_tracking_sources, :cutoff_enforcement_starts_on, :date, default: "2026-10-16"
    add_check_constraint :time_tracking_sources,
      "(source_type <> 'aire_services' OR cutoff_enforcement_starts_on IS NOT NULL) AND (cutoff_enforcement_starts_on IS NULL OR EXTRACT(DAY FROM cutoff_enforcement_starts_on) IN (1, 16))",
      name: "time_tracking_lock_rollout_period_start"

    execute <<~SQL
      CREATE FUNCTION protect_time_tracking_lock_rollout() RETURNS trigger AS $$
      BEGIN
        IF NEW.cutoff_enforcement_starts_on IS DISTINCT FROM OLD.cutoff_enforcement_starts_on THEN
          RAISE EXCEPTION 'the configured payroll lock rollout boundary is immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER time_tracking_lock_rollout_immutable BEFORE UPDATE ON time_tracking_sources
      FOR EACH ROW EXECUTE FUNCTION protect_time_tracking_lock_rollout();

      CREATE FUNCTION audit_time_tracking_lock_rollout() RETURNS trigger AS $$
      BEGIN
        IF NEW.source_type = 'aire_services' THEN
          INSERT INTO audit_logs (action, actor_name, actor_role, company_id, organization_id,
            record_type, record_id, event_category, metadata, created_at)
          SELECT 'time_tracking_source#lock_rollout_configured', 'Approved lock rollout', 'system',
            NEW.company_id, companies.organization_id, 'TimeTrackingSource', NEW.id, 'integration',
            jsonb_build_object('cutoff_enforcement_starts_on', NEW.cutoff_enforcement_starts_on,
              'reason', 'Approved rollout: periods before October 16, 2026 lock only on explicit operator request'),
            CURRENT_TIMESTAMP
          FROM companies WHERE companies.id = NEW.company_id;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER time_tracking_lock_rollout_audit AFTER INSERT ON time_tracking_sources
      FOR EACH ROW EXECUTE FUNCTION audit_time_tracking_lock_rollout();

      INSERT INTO audit_logs (action, actor_name, actor_role, company_id, organization_id,
        record_type, record_id, event_category, metadata, created_at)
      SELECT 'time_tracking_source#lock_rollout_configured', 'Approved lock rollout migration', 'system',
        sources.company_id, companies.organization_id, 'TimeTrackingSource', sources.id, 'integration',
        jsonb_build_object('cutoff_enforcement_starts_on', sources.cutoff_enforcement_starts_on,
          'reason', 'Approved rollout: periods before October 16, 2026 lock only on explicit operator request'), CURRENT_TIMESTAMP
      FROM time_tracking_sources sources JOIN companies ON companies.id = sources.company_id
      WHERE sources.source_type = 'aire_services';
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve the audited payroll lock rollout boundary"
  end
end
