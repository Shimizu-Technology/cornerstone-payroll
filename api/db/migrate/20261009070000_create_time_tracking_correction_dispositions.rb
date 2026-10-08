# frozen_string_literal: true

class CreateTimeTrackingCorrectionDispositions < ActiveRecord::Migration[8.0]
  def change
    create_table :time_tracking_correction_dispositions do |t|
      t.references :company, null: false, foreign_key: true
      t.references :time_tracking_source, null: false, foreign_key: true
      t.references :time_tracking_import, null: false, foreign_key: true
      t.references :original_allocation, null: false, foreign_key: { to_table: :time_tracking_entry_allocations }
      t.references :corrective_payroll_item, null: false, foreign_key: { to_table: :payroll_items }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.string :source_instance_id, null: false
      t.string :batch_id, null: false
      t.string :batch_checksum, null: false
      t.string :source_user_id, null: false
      t.string :source_user_uuid, null: false
      t.string :source_time_entry_id, null: false
      t.string :line_key, null: false
      t.string :source_kind, null: false
      t.jsonb :line_snapshot, null: false
      t.string :proof_digest, null: false
      t.string :reason, null: false
      t.decimal :total_hours, precision: 12, scale: 2, null: false
      t.decimal :regular_hours, precision: 12, scale: 2, null: false
      t.decimal :overtime_hours, precision: 12, scale: 2, null: false
      t.timestamps
    end
    add_index :time_tracking_correction_dispositions,
      [ :time_tracking_source_id, :source_instance_id, :batch_id, :source_time_entry_id, :line_key ],
      unique: true, name: 'idx_correction_disposition_exact_line'
    add_index :time_tracking_correction_dispositions, :corrective_payroll_item_id,
      unique: true, name: 'idx_correction_disposition_corrective_item'
    create_table :time_tracking_correction_receipts do |t|
      t.references :time_tracking_correction_disposition, null: false, foreign_key: true, index: { unique: true, name: 'idx_correction_receipt_disposition' }
      t.string :event_id, null: false
      t.jsonb :payload, null: false
      t.datetime :enqueued_at
      t.datetime :delivered_at
      t.text :last_error
      t.timestamps
    end
    add_index :time_tracking_correction_receipts, :event_id, unique: true
    add_check_constraint :time_tracking_correction_dispositions,
      "source_kind = 'correction' AND total_hours = regular_hours + overtime_hours AND total_hours < 0 AND regular_hours <= 0 AND overtime_hours <= 0",
      name: "correction_disposition_signed_hours"
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE FUNCTION prevent_time_tracking_correction_evidence_mutation() RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION 'Exact source accounting correction evidence is append-only';
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER immutable_time_tracking_correction_dispositions
            BEFORE UPDATE OR DELETE ON time_tracking_correction_dispositions
            FOR EACH ROW EXECUTE FUNCTION prevent_time_tracking_correction_evidence_mutation();
          CREATE FUNCTION protect_time_tracking_correction_receipt_evidence() RETURNS trigger AS $$
          BEGIN
            IF TG_OP = 'DELETE' OR NEW.payload IS DISTINCT FROM OLD.payload OR
              NEW.event_id IS DISTINCT FROM OLD.event_id OR
              NEW.time_tracking_correction_disposition_id IS DISTINCT FROM OLD.time_tracking_correction_disposition_id THEN
              RAISE EXCEPTION 'Exact source accounting receipt evidence is immutable';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER immutable_time_tracking_correction_receipts
            BEFORE UPDATE OR DELETE ON time_tracking_correction_receipts
            FOR EACH ROW EXECUTE FUNCTION protect_time_tracking_correction_receipt_evidence();
        SQL
      end
      dir.down do
        execute "DROP TRIGGER immutable_time_tracking_correction_receipts ON time_tracking_correction_receipts"
        execute "DROP FUNCTION protect_time_tracking_correction_receipt_evidence()"
        execute "DROP TRIGGER immutable_time_tracking_correction_dispositions ON time_tracking_correction_dispositions"
        execute "DROP FUNCTION prevent_time_tracking_correction_evidence_mutation()"
      end
    end
  end
end
