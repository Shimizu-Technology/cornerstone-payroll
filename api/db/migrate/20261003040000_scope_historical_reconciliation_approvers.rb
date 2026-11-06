# frozen_string_literal: true

class ScopeHistoricalReconciliationApprovers < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION historical_time_reconciliation_actor_allowed(actor_id bigint, target_company_id bigint)
      RETURNS boolean AS $$
        SELECT EXISTS (
          SELECT 1 FROM users u JOIN companies c ON c.id = target_company_id
          JOIN organizations o ON o.id = c.organization_id
          WHERE u.id = actor_id AND u.active = true AND c.active = true
            AND c.test_workspace_archived_at IS NULL AND o.status = 'active'
            AND (u.role = 5 OR (u.organization_id = c.organization_id AND (
              u.role IN (0,6) OR (u.role IN (1,3) AND (
                EXISTS (SELECT 1 FROM company_assignments ca WHERE ca.user_id = u.id AND ca.company_id = c.id
                  AND (ca.expires_at IS NULL OR ca.expires_at > CURRENT_TIMESTAMP))
                OR (u.company_id = c.id AND NOT EXISTS (
                  SELECT 1 FROM company_assignments ca JOIN companies assigned ON assigned.id = ca.company_id
                  WHERE ca.user_id = u.id AND assigned.organization_id = u.organization_id
                    AND assigned.test_workspace_archived_at IS NULL
                    AND (ca.expires_at IS NULL OR ca.expires_at > CURRENT_TIMESTAMP)
                ))
              ))
            )))
        );
      $$ LANGUAGE sql STABLE;

      CREATE OR REPLACE FUNCTION protect_legacy_identity_binding() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          RAISE EXCEPTION 'Legacy identity bindings are append-only';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM time_tracking_entry_allocations a
          JOIN time_tracking_imports i ON i.id = a.time_tracking_import_id
          JOIN time_tracking_sources s ON s.id = a.time_tracking_source_id
          JOIN payroll_items p ON p.id = a.payroll_item_id
          JOIN employees e ON e.id = a.employee_id
          JOIN pay_periods pp ON pp.id = a.pay_period_id
          JOIN companies c ON c.id = a.company_id
          JOIN users u ON u.id = NEW.approved_by_id
          JOIN time_tracking_employee_mappings m ON m.id = NEW.time_tracking_employee_mapping_id
          WHERE a.id = NEW.time_tracking_entry_allocation_id AND a.source_user_uuid IS NULL
            AND a.company_id = NEW.company_id AND s.company_id = c.id AND p.company_id = c.id
            AND e.company_id = c.id AND pp.company_id = c.id AND p.employee_id = e.id
            AND p.pay_period_id = pp.id AND i.pay_period_id = pp.id AND i.time_tracking_source_id = s.id
            AND a.time_tracking_source_id = NEW.time_tracking_source_id AND a.employee_id = NEW.employee_id
            AND a.source_user_id = NEW.source_user_id AND a.source_time_entry_id = NEW.source_time_entry_id
            AND a.line_key = NEW.source_line_key AND a.original_work_date = NEW.original_work_date
            AND i.external_batch_id = NEW.external_batch_id AND i.external_batch_checksum = NEW.batch_checksum
            AND s.expected_source_instance_id::text = NEW.source_instance_id::text
            AND m.company_id = c.id AND m.time_tracking_source_id = s.id AND m.employee_id = e.id
            AND m.source_user_id = a.source_user_id AND (m.source_user_uuid IS NULL OR m.source_user_uuid::text = NEW.source_user_uuid::text)
            AND historical_time_reconciliation_actor_allowed(u.id, c.id)
        ) THEN
          RAISE EXCEPTION 'Legacy identity binding tenant, source, owner, or batch evidence changed';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE OR REPLACE FUNCTION protect_verified_history_receipt() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Verified history receipts are append-only'; END IF;
        IF NEW.coverage_verified AND (
          NEW.accepted_manifest_sha256 IS DISTINCT FROM NEW.manifest_sha256 OR
          NEW.source_instance_id IS NULL OR NEW.release_owner IS NULL OR length(btrim(NEW.release_owner)) = 0 OR
          NOT EXISTS (SELECT 1 FROM time_tracking_sources s JOIN companies c ON c.id = s.company_id
            JOIN users u ON u.id = NEW.approved_by_id WHERE s.id = NEW.time_tracking_source_id
            AND s.company_id = NEW.company_id AND s.expected_source_instance_id::text = NEW.source_instance_id::text
            AND historical_time_reconciliation_actor_allowed(u.id, c.id))
        ) THEN RAISE EXCEPTION 'Verified history receipt requires accepted installation-bound owner approval'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Do not broaden or rewrite historical approval authority on rollback"
  end
end
