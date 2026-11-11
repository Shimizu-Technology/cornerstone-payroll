# frozen_string_literal: true

class AddClientDocumentSafetyAndArchival < ActiveRecord::Migration[8.1]
  def up
    add_column :client_documents, :scan_status, :string, null: false, default: "not_scanned"
    add_column :client_documents, :archived_at, :datetime
    add_reference :client_documents, :archived_by, foreign_key: { to_table: :users }
    add_check_constraint :client_documents, "scan_status IN ('not_scanned','pending','clean','infected','error')", name: "client_document_scan_status"
    execute <<~SQL
      CREATE OR REPLACE FUNCTION protect_retained_client_documents() RETURNS trigger AS $$
      BEGIN
        IF OLD.archived_at IS NOT NULL OR
          EXISTS (SELECT 1 FROM client_portal_messages WHERE client_document_id = OLD.id) OR
          EXISTS (SELECT 1 FROM employee_document_requirements WHERE client_document_id = OLD.id) OR
          EXISTS (SELECT 1 FROM employee_document_requirement_events WHERE client_document_id = OLD.id) OR
          EXISTS (SELECT 1 FROM payroll_filing_events WHERE evidence_document_id = OLD.id) THEN
          RAISE EXCEPTION 'Retained portal files must be archived, not deleted';
        END IF;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql;
      DROP TRIGGER IF EXISTS retained_client_documents_delete ON client_documents;
      CREATE TRIGGER retained_client_documents_delete BEFORE DELETE ON client_documents
        FOR EACH ROW EXECUTE FUNCTION protect_retained_client_documents();
    SQL
  end

  def down
    execute "DROP TRIGGER retained_client_documents_delete ON client_documents"
    execute "DROP FUNCTION protect_retained_client_documents()"
    remove_check_constraint :client_documents, name: "client_document_scan_status"
    remove_reference :client_documents, :archived_by, foreign_key: { to_table: :users }
    remove_column :client_documents, :archived_at
    remove_column :client_documents, :scan_status
  end
end
