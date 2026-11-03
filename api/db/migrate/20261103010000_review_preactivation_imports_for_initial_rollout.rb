# frozen_string_literal: true

class ReviewPreactivationImportsForInitialRollout < ActiveRecord::Migration[8.1]
  def up
    add_column :time_tracking_lock_rollout_selections, :historical_import_review, :jsonb, null: false, default: {}
    execute <<~SQL
      CREATE FUNCTION historical_imports_precede_rollout(source_id bigint) RETURNS boolean AS $$
        SELECT NOT EXISTS (
          SELECT 1 FROM time_tracking_imports i
          JOIN time_tracking_sources s ON s.id = i.time_tracking_source_id
          LEFT JOIN pay_periods p ON p.id = i.pay_period_id
          WHERE i.time_tracking_source_id = source_id AND NOT COALESCE(
            p.company_id = s.company_id AND p.status = 'committed'
            AND p.start_date = i.start_date AND p.end_date = i.end_date
            AND p.committed_at < s.cutoff_enforcement_starts_on
            AND i.created_at < s.cutoff_enforcement_starts_on
            AND i.end_date < s.cutoff_enforcement_starts_on
            AND i.fetch_end_date < s.cutoff_enforcement_starts_on
            AND i.raw_payload->>'source' = 'aire_services'
            AND i.raw_payload->>'allocation_contract_version' IS NULL
            AND i.raw_payload->>'overtime_policy' IS NULL
            AND i.raw_payload->>'calendar' IS NULL
            AND i.raw_payload->>'payroll_calendar_period_id' IS NULL
            AND i.raw_payload->>'target_external_pay_period_id' IS NULL
            AND (
              (i.status = 'previewed' AND i.external_batch_id IS NULL AND i.external_batch_checksum IS NULL
                AND i.contract_version IS NULL AND i.source_cutoff_at IS NULL AND i.raw_payload->'export' IS NULL)
              OR
              (i.status = 'applied' AND i.contract_version = '2.0'
                AND i.raw_payload->>'schema_version' = i.contract_version
                AND i.raw_payload->>'batch_id' = i.external_batch_id
                AND i.raw_payload->'export'->>'checksum' = i.external_batch_checksum
                AND i.source_cutoff_at < s.cutoff_enforcement_starts_on
                AND i.source_processing_status = 'committed'
                AND i.source_processing_event_occurred_at = p.committed_at)
            ), false)
        );
      $$ LANGUAGE sql STABLE;

      CREATE FUNCTION historical_import_rollout_review(source_id bigint) RETURNS jsonb AS $$
        WITH inventory AS (
          SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'import_id', i.id, 'run_id', p.id,
            'import_sha256', encode(sha256(convert_to(to_jsonb(i)::text, 'UTF8')), 'hex'),
            'run_sha256', encode(sha256(convert_to(to_jsonb(p)::text, 'UTF8')), 'hex')
          ) ORDER BY i.id), '[]'::jsonb) AS rows
          FROM time_tracking_imports i JOIN pay_periods p ON p.id = i.pay_period_id
          WHERE i.time_tracking_source_id = source_id
        ) SELECT jsonb_build_object('inventory', rows,
          'sha256', encode(sha256(convert_to(rows::text, 'UTF8')), 'hex')) FROM inventory;
      $$ LANGUAGE sql STABLE;

      CREATE OR REPLACE FUNCTION protect_initial_time_tracking_lock_rollout() RETURNS trigger AS $$
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
          OR EXISTS (SELECT 1 FROM audit_logs WHERE record_type = 'TimeTrackingSource' AND record_id = NEW.time_tracking_source_id
            AND action = 'time_tracking_source#lock_rollout_gate_passed') THEN
          RAISE EXCEPTION 'initial payroll rollout selection requires an unused, ungated source';
        END IF;
        LOCK TABLE time_tracking_imports, pay_periods IN SHARE MODE;
        IF EXISTS (SELECT 1 FROM time_tracking_imports WHERE time_tracking_source_id = NEW.time_tracking_source_id) THEN
          IF NOT historical_imports_precede_rollout(NEW.time_tracking_source_id)
            OR NEW.historical_import_review IS DISTINCT FROM historical_import_rollout_review(NEW.time_tracking_source_id) THEN
            RAISE EXCEPTION 'initial payroll rollout selection requires exact reviewed preactivation import evidence';
          END IF;
        ELSIF NEW.historical_import_review <> '{}'::jsonb THEN
          RAISE EXCEPTION 'unused historical import evidence';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve reviewed historical import evidence"
  end
end
