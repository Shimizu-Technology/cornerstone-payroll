# frozen_string_literal: true

# Filing evidence, liability postings and external time-tracking sources are
# real-world records. A demo company never has any, including through direct
# SQL, so the database refuses them as well as the models.
class RefuseDemoCompanyExternalRecords < ActiveRecord::Migration[8.1]
  TABLES = %w[payroll_filing_records payroll_filing_events payroll_liability_postings payroll_liability_entries time_tracking_sources].freeze

  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_demo_company_external_records() RETURNS trigger AS $$
      BEGIN
        IF EXISTS (SELECT 1 FROM companies WHERE id = NEW.company_id AND COALESCE(test_workspace_purpose, '') = 'demo') THEN
          RAISE EXCEPTION '% cannot belong to a demo company', TG_TABLE_NAME
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS payroll_filing_records_refuse_demo_company ON payroll_filing_records;
      CREATE TRIGGER payroll_filing_records_refuse_demo_company
      BEFORE INSERT OR UPDATE OF company_id ON payroll_filing_records
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_external_records();

      DROP TRIGGER IF EXISTS payroll_filing_events_refuse_demo_company ON payroll_filing_events;
      CREATE TRIGGER payroll_filing_events_refuse_demo_company
      BEFORE INSERT OR UPDATE OF company_id ON payroll_filing_events
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_external_records();

      DROP TRIGGER IF EXISTS payroll_liability_postings_refuse_demo_company ON payroll_liability_postings;
      CREATE TRIGGER payroll_liability_postings_refuse_demo_company
      BEFORE INSERT OR UPDATE OF company_id ON payroll_liability_postings
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_external_records();

      DROP TRIGGER IF EXISTS payroll_liability_entries_refuse_demo_company ON payroll_liability_entries;
      CREATE TRIGGER payroll_liability_entries_refuse_demo_company
      BEFORE INSERT OR UPDATE OF company_id ON payroll_liability_entries
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_external_records();

      DROP TRIGGER IF EXISTS time_tracking_sources_refuse_demo_company ON time_tracking_sources;
      CREATE TRIGGER time_tracking_sources_refuse_demo_company
      BEFORE INSERT OR UPDATE OF company_id ON time_tracking_sources
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_external_records();
    SQL
  end

  def down
    TABLES.each { |table| execute "DROP TRIGGER IF EXISTS #{table}_refuse_demo_company ON #{table};" }
    execute "DROP FUNCTION IF EXISTS prevent_demo_company_external_records();"
  end
end
