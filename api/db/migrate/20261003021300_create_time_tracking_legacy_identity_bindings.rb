# frozen_string_literal: true
class CreateTimeTrackingLegacyIdentityBindings < ActiveRecord::Migration[8.1]
  def change
    create_table :time_tracking_legacy_identity_bindings do |t|
      t.references :time_tracking_entry_allocation, null: false, foreign_key: true, index: { unique: true, name: "idx_legacy_binding_allocation" }
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true, index: { name: "idx_legacy_binding_source" }
      t.references :employee, null: false, foreign_key: true
      t.references :time_tracking_employee_mapping, null: false, foreign_key: true, index: { name: "idx_legacy_binding_mapping" }
      t.references :approved_by, null: false, foreign_key: { to_table: :users }
      t.uuid :source_user_uuid, null: false
      t.uuid :source_instance_id, null: false
      t.string :source_user_id, null: false
      t.string :source_time_entry_id, null: false
      t.integer :source_time_entry_version, null: false
      t.string :source_line_key, null: false
      t.date :original_work_date, null: false
      t.string :external_batch_id, null: false
      t.string :batch_checksum, limit: 64, null: false
      t.string :accepted_manifest_sha256, limit: 64, null: false
      t.string :release_owner, null: false
      t.decimal :source_total_hours, precision: 8, scale: 2, null: false
      t.datetime :created_at, null: false
    end
    add_check_constraint :time_tracking_legacy_identity_bindings,
      "source_time_entry_version >= 0 AND batch_checksum ~ '^[0-9a-f]{64}$' AND accepted_manifest_sha256 ~ '^[0-9a-f]{64}$' AND length(btrim(release_owner)) > 0",
      name: "legacy_identity_binding_evidence_shape"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_legacy_identity_binding() RETURNS trigger AS $$
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
                AND u.organization_id = c.organization_id AND u.active = true AND u.role IN (0,1,5,6)
            ) THEN
              RAISE EXCEPTION 'Legacy identity binding tenant, source, owner, or batch evidence changed';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER legacy_identity_binding_integrity
          BEFORE INSERT OR UPDATE OR DELETE ON time_tracking_legacy_identity_bindings
          FOR EACH ROW EXECUTE FUNCTION protect_legacy_identity_binding();

          CREATE FUNCTION protect_bound_legacy_allocation() RETURNS trigger AS $$
          BEGIN
            IF EXISTS (SELECT 1 FROM time_tracking_legacy_identity_bindings WHERE time_tracking_entry_allocation_id = OLD.id) THEN
              RAISE EXCEPTION 'An allocation with approved legacy identity evidence is immutable';
            END IF;
            IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER bound_legacy_allocation_immutable
          BEFORE UPDATE OR DELETE ON time_tracking_entry_allocations
          FOR EACH ROW EXECUTE FUNCTION protect_bound_legacy_allocation();
        SQL
      end
      direction.down do
        execute "DROP TRIGGER IF EXISTS bound_legacy_allocation_immutable ON time_tracking_entry_allocations; DROP FUNCTION IF EXISTS protect_bound_legacy_allocation(); DROP FUNCTION IF EXISTS protect_legacy_identity_binding() CASCADE;"
      end
    end
  end
end
