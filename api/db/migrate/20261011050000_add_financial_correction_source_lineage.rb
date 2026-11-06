# frozen_string_literal: true

class AddFinancialCorrectionSourceLineage < ActiveRecord::Migration[8.1]
  def up
    add_reference :payroll_items, :financial_correction_origin_item, foreign_key: { to_table: :payroll_items, on_delete: :restrict }
    create_table :time_tracking_financial_correction_links do |t|
      t.references :original_allocation, null: false, foreign_key: { to_table: :time_tracking_entry_allocations, on_delete: :restrict }
      t.references :predecessor_payroll_item, null: false, foreign_key: { to_table: :payroll_items, on_delete: :restrict }
      t.references :payroll_item, null: false, foreign_key: { on_delete: :restrict }
      t.uuid :command_id, null: false
      t.uuid :event_id, null: false
      t.jsonb :payload, null: false
      t.string :request_digest, null: false
      t.jsonb :accepted_receipt, null: false, default: {}
      t.datetime :accepted_at
      t.timestamps
    end
    add_index :time_tracking_financial_correction_links, [ :original_allocation_id, :predecessor_payroll_item_id ], unique: true, name: "idx_financial_source_successor_generation"
    add_index :time_tracking_financial_correction_links, [ :original_allocation_id, :payroll_item_id ], unique: true, name: "idx_financial_source_successor_item"
    add_index :time_tracking_financial_correction_links, :command_id, unique: true
    add_index :time_tracking_financial_correction_links, :event_id, unique: true
    add_check_constraint :time_tracking_financial_correction_links,
      "(accepted_receipt = '{}'::jsonb AND accepted_at IS NULL) OR (jsonb_typeof(accepted_receipt) = 'object' AND accepted_receipt <> '{}'::jsonb AND accepted_at IS NOT NULL)",
      name: "financial_source_acceptance_pair"
    add_reference :aire_payroll_entry_acknowledgements, :financial_correction_link, foreign_key: { to_table: :time_tracking_financial_correction_links, on_delete: :restrict }
    add_column :aire_payroll_entry_acknowledgements, :wire_payload, :jsonb, null: false, default: {}
    execute protection_sql
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Financial correction Source evidence is append-only"
  end

  def protection_sql
    <<~SQL
      CREATE FUNCTION protect_financial_correction_source_evidence() RETURNS trigger AS $$
      BEGIN
        IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
          RAISE EXCEPTION 'Financial correction Source evidence is append-only';
        END IF;
        IF (to_jsonb(NEW) - ARRAY['accepted_receipt','accepted_at','updated_at']) IS DISTINCT FROM
           (to_jsonb(OLD) - ARRAY['accepted_receipt','accepted_at','updated_at']) OR
           (OLD.accepted_receipt <> '{}'::jsonb AND (NEW.accepted_receipt IS DISTINCT FROM OLD.accepted_receipt OR NEW.accepted_at IS DISTINCT FROM OLD.accepted_at)) THEN
          RAISE EXCEPTION 'Financial correction Source evidence is immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER immutable_financial_correction_source_links BEFORE UPDATE OR DELETE ON time_tracking_financial_correction_links
        FOR EACH ROW EXECUTE FUNCTION protect_financial_correction_source_evidence();
      CREATE TRIGGER immutable_financial_correction_source_links_truncate BEFORE TRUNCATE ON time_tracking_financial_correction_links
        FOR EACH STATEMENT EXECUTE FUNCTION protect_financial_correction_source_evidence();
      CREATE FUNCTION protect_financial_correction_origin_and_outbox() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'TRUNCATE' THEN
          IF EXISTS (SELECT 1 FROM aire_payroll_entry_acknowledgements WHERE financial_correction_link_id IS NOT NULL) THEN
            RAISE EXCEPTION 'Financial correction outbox is append-only';
          END IF;
          RETURN NULL;
        END IF;
        IF TG_OP = 'DELETE' THEN
          IF OLD.financial_correction_link_id IS NOT NULL THEN
            RAISE EXCEPTION 'Financial correction outbox is append-only';
          END IF;
          RETURN OLD;
        END IF;
        IF TG_TABLE_NAME = 'payroll_items' THEN
          IF OLD.financial_correction_origin_item_id IS NOT NULL AND NEW.financial_correction_origin_item_id IS DISTINCT FROM OLD.financial_correction_origin_item_id THEN
            RAISE EXCEPTION 'Financial correction origin is immutable';
          END IF;
        ELSE
          IF NEW.financial_correction_link_id IS DISTINCT FROM OLD.financial_correction_link_id OR NEW.wire_payload IS DISTINCT FROM OLD.wire_payload OR
             (OLD.financial_correction_link_id IS NOT NULL AND
              (to_jsonb(NEW) - ARRAY['delivered_at','enqueued_at','last_error','updated_at']) IS DISTINCT FROM
              (to_jsonb(OLD) - ARRAY['delivered_at','enqueued_at','last_error','updated_at'])) THEN
            RAISE EXCEPTION 'Financial correction outbox payload is immutable';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER immutable_financial_correction_origin BEFORE UPDATE ON payroll_items
        FOR EACH ROW EXECUTE FUNCTION protect_financial_correction_origin_and_outbox();
      CREATE TRIGGER immutable_financial_correction_outbox BEFORE UPDATE OR DELETE ON aire_payroll_entry_acknowledgements
        FOR EACH ROW EXECUTE FUNCTION protect_financial_correction_origin_and_outbox();
      CREATE TRIGGER immutable_financial_correction_outbox_truncate BEFORE TRUNCATE ON aire_payroll_entry_acknowledgements
        FOR EACH STATEMENT EXECUTE FUNCTION protect_financial_correction_origin_and_outbox();
    SQL
  end
end
