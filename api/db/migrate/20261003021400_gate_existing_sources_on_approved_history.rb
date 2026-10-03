# frozen_string_literal: true

class GateExistingSourcesOnApprovedHistory < ActiveRecord::Migration[8.1]
  def change
    add_column :time_tracking_sources, :historical_reconciliation_required, :boolean, null: false, default: false
    reversible { |direction| direction.up { execute "UPDATE time_tracking_sources SET historical_reconciliation_required = true" } }
    add_column :aire_verified_history_rollout_receipts, :source_instance_id, :uuid
    add_column :aire_verified_history_rollout_receipts, :accepted_manifest_sha256, :string, limit: 64
    add_reference :aire_verified_history_rollout_receipts, :approved_by, foreign_key: { to_table: :users }, index: { name: "idx_verified_history_approver" }
    add_column :aire_verified_history_rollout_receipts, :release_owner, :string
    add_column :aire_verified_history_rollout_receipts, :coverage_verified, :boolean, null: false, default: false
    remove_index :aire_verified_history_rollout_receipts, :manifest_sha256, unique: true, name: "idx_aire_verified_rollout_receipts_manifest"
    add_index :aire_verified_history_rollout_receipts, [ :time_tracking_source_id, :manifest_sha256, :coverage_verified ],
      unique: true, name: "idx_verified_history_manifest_approval"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION protect_verified_history_receipt() RETURNS trigger AS $$
          BEGIN
            IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Verified history receipts are append-only'; END IF;
            IF NEW.coverage_verified AND (
              NEW.accepted_manifest_sha256 IS DISTINCT FROM NEW.manifest_sha256 OR
              NEW.source_instance_id IS NULL OR NEW.release_owner IS NULL OR length(btrim(NEW.release_owner)) = 0 OR
              NOT EXISTS (SELECT 1 FROM time_tracking_sources s JOIN companies c ON c.id = s.company_id
                JOIN users u ON u.id = NEW.approved_by_id WHERE s.id = NEW.time_tracking_source_id
                AND s.company_id = NEW.company_id AND s.expected_source_instance_id::text = NEW.source_instance_id::text
                AND u.organization_id = c.organization_id AND u.active = true AND u.role IN (0,1,5,6))
            ) THEN RAISE EXCEPTION 'Verified history receipt requires accepted installation-bound owner approval'; END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER verified_history_receipt_integrity BEFORE INSERT OR UPDATE OR DELETE
          ON aire_verified_history_rollout_receipts FOR EACH ROW EXECUTE FUNCTION protect_verified_history_receipt();
        SQL
      end
      direction.down { execute "DROP FUNCTION IF EXISTS protect_verified_history_receipt() CASCADE" }
    end
  end
end
