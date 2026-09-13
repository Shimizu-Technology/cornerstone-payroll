# frozen_string_literal: true

class CreatePayrollFilingRecords < ActiveRecord::Migration[8.0]
  def up
    create_table :payroll_filing_records do |t|
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.string :filing_type, null: false
      t.integer :tax_year, null: false
      t.integer :quarter
      t.string :status, null: false, default: "submitted"
      t.datetime :submitted_at, null: false
      t.datetime :resolved_at
      t.string :confirmation_number, null: false
      t.string :source_fingerprint, null: false
      t.jsonb :source_snapshot, null: false, default: {}
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :payroll_filing_records,
              [ :company_id, :filing_type, :tax_year, :quarter ],
              unique: true,
              where: "quarter IS NOT NULL",
              name: "idx_payroll_filings_quarterly_identity"
    add_index :payroll_filing_records,
              [ :company_id, :filing_type, :tax_year ],
              unique: true,
              where: "quarter IS NULL",
              name: "idx_payroll_filings_annual_identity"
    add_index :payroll_filing_records,
              [ :id, :company_id ],
              unique: true,
              name: "idx_payroll_filing_records_tenant_key"
    add_check_constraint :payroll_filing_records,
                         "(filing_type IN ('w2_gu_w3_ss', 'form_1099_nec') AND quarter IS NULL) OR " \
                         "(filing_type IN ('form_500_payment', 'w1', 'swica', 'federal_941') AND quarter BETWEEN 1 AND 4)",
                         name: "payroll_filing_records_identity"
    add_check_constraint :payroll_filing_records,
                         "tax_year BETWEEN 2000 AND 2200",
                         name: "payroll_filing_records_tax_year"
    add_check_constraint :payroll_filing_records,
                         "status IN ('submitted', 'accepted', 'accepted_with_errors', 'rejected', 'needs_correction')",
                         name: "payroll_filing_records_status"

    create_table :payroll_filing_events do |t|
      t.references :payroll_filing_record, null: false, foreign_key: { on_delete: :restrict }
      t.references :company, null: false, foreign_key: { on_delete: :restrict }
      t.references :recorded_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict }
      t.references :evidence_document, null: false, foreign_key: { to_table: :client_documents, on_delete: :restrict }
      t.string :event_type, null: false
      t.string :from_status
      t.string :to_status, null: false
      t.datetime :occurred_at, null: false
      t.string :reference_number, null: false
      t.string :preparer_name, null: false
      t.string :signer_name
      t.string :signer_title
      t.text :notes
      t.string :source_fingerprint, null: false
      t.jsonb :source_snapshot, null: false, default: {}
      t.string :idempotency_key, null: false
      t.timestamps
    end

    add_index :payroll_filing_events,
              [ :company_id, :idempotency_key ],
              unique: true,
              name: "idx_payroll_filing_events_idempotency"
    add_index :payroll_filing_events,
              [ :payroll_filing_record_id, :occurred_at, :id ],
              name: "idx_payroll_filing_events_timeline"
    add_check_constraint :payroll_filing_events,
                         "event_type IN ('submitted', 'resubmitted', 'accepted', 'accepted_with_errors', 'rejected', 'correction_needed')",
                         name: "payroll_filing_events_type"
    add_check_constraint :payroll_filing_events,
                         "from_status IS NULL OR from_status IN ('submitted', 'accepted', 'accepted_with_errors', 'rejected', 'needs_correction')",
                         name: "payroll_filing_events_from_status"
    add_check_constraint :payroll_filing_events,
                         "to_status IN ('submitted', 'accepted', 'accepted_with_errors', 'rejected', 'needs_correction')",
                         name: "payroll_filing_events_to_status"

    add_foreign_key :payroll_filing_events,
                    :payroll_filing_records,
                    column: [ :payroll_filing_record_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_payroll_filing_events_record_tenant"
    add_foreign_key :payroll_filing_events,
                    :client_documents,
                    column: [ :evidence_document_id, :company_id ],
                    primary_key: [ :id, :company_id ],
                    name: "fk_payroll_filing_events_document_tenant"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_payroll_filing_event_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'payroll_filing_events are append-only';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER payroll_filing_events_append_only
      BEFORE UPDATE OR DELETE ON payroll_filing_events
      FOR EACH ROW EXECUTE FUNCTION prevent_payroll_filing_event_mutation();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS payroll_filing_events_append_only ON payroll_filing_events"
    execute "DROP FUNCTION IF EXISTS prevent_payroll_filing_event_mutation()"
    drop_table :payroll_filing_events
    drop_table :payroll_filing_records
  end
end
