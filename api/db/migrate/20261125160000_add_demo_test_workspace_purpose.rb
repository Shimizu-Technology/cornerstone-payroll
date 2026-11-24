# frozen_string_literal: true

# A demo company is a permanent, source-free test workspace. It stays in the
# migration_rehearsal environment so every live-only selector keeps excluding
# it, but it never expires, archives or seals, and it can never be converted to
# or from a live client or another workspace purpose.
class AddDemoTestWorkspacePurpose < ActiveRecord::Migration[8.1]
  PURPOSES_WITH_DEMO = "'sandbox', 'migration_rehearsal', 'training_replay', 'backup_snapshot', 'demo'"
  PURPOSES_WITHOUT_DEMO = "'sandbox', 'migration_rehearsal', 'training_replay', 'backup_snapshot'"

  def up
    remove_check_constraint :companies, name: "companies_test_workspace_purpose_check"
    add_check_constraint :companies,
                         "test_workspace_purpose IS NULL OR test_workspace_purpose IN (#{PURPOSES_WITH_DEMO})",
                         name: "companies_test_workspace_purpose_check"

    remove_check_constraint :companies, name: "companies_test_workspace_shape_check"
    add_check_constraint :companies, <<~SQL.squish, name: "companies_test_workspace_shape_check"
      (
        payroll_environment = 'live'
        AND migration_source_company_id IS NULL
        AND migration_source_batch_id IS NULL
        AND migration_rehearsal_status IS NULL
        AND test_workspace_purpose IS NULL
      )
      OR
      (
        payroll_environment = 'migration_rehearsal'
        AND test_workspace_purpose = 'demo'
        AND migration_source_company_id IS NULL
        AND migration_source_batch_id IS NULL
        AND migration_rehearsal_status IS NOT NULL
        AND test_workspace_expires_at IS NULL
        AND test_workspace_archived_at IS NULL
        AND test_workspace_sealed_at IS NULL
      )
      OR
      (
        payroll_environment = 'migration_rehearsal'
        AND test_workspace_purpose <> 'demo'
        AND migration_source_company_id IS NOT NULL
        AND migration_rehearsal_status IS NOT NULL
        AND test_workspace_purpose IS NOT NULL
        AND (
          test_workspace_purpose <> 'migration_rehearsal'
          OR migration_source_batch_id IS NOT NULL
        )
      )
    SQL

    remove_check_constraint :companies, name: "company_subdomain_requires_live_payroll"
    add_check_constraint :companies,
                         "subdomain_slug IS NULL OR payroll_environment = 'live' OR " \
                         "(payroll_environment = 'migration_rehearsal' AND test_workspace_purpose = 'demo')",
                         name: "company_subdomain_requires_live_payroll"
    # The live-only index stays; this one also reserves a demo's slug against
    # every live client and every other demo.
    add_index :companies, "lower(subdomain_slug)",
              unique: true,
              where: "subdomain_slug IS NOT NULL AND (payroll_environment = 'live' OR test_workspace_purpose = 'demo')",
              name: "index_live_and_demo_companies_on_lower_subdomain_slug"

    add_index :companies, "organization_id, (test_workspace_manifest ->> 'demo_fixture_key')",
              unique: true,
              where: "test_workspace_purpose = 'demo'",
              name: "index_demo_companies_on_organization_fixture_key"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_demo_company_conversion() RETURNS trigger AS $$
      BEGIN
        IF (COALESCE(OLD.test_workspace_purpose, '') = 'demo') <> (COALESCE(NEW.test_workspace_purpose, '') = 'demo')
          OR (COALESCE(OLD.test_workspace_purpose, '') = 'demo' AND OLD.payroll_environment IS DISTINCT FROM NEW.payroll_environment) THEN
          RAISE EXCEPTION 'demo companies cannot be converted to or from another company type'
            USING ERRCODE = 'check_violation';
        END IF;
        IF COALESCE(OLD.test_workspace_purpose, '') = 'demo'
          AND (OLD.test_workspace_manifest ->> 'demo_fixture_key') IS DISTINCT FROM (NEW.test_workspace_manifest ->> 'demo_fixture_key') THEN
          RAISE EXCEPTION 'demo fixture keys are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS companies_demo_shape_immutable ON companies;
      CREATE TRIGGER companies_demo_shape_immutable
      BEFORE UPDATE OF payroll_environment, test_workspace_purpose, test_workspace_manifest ON companies
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_conversion();
    SQL
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM companies WHERE test_workspace_purpose = 'demo')")
      raise ActiveRecord::IrreversibleMigration, "Remove demo companies before rolling back this migration"
    end

    execute <<~SQL
      DROP TRIGGER IF EXISTS companies_demo_shape_immutable ON companies;
      DROP FUNCTION IF EXISTS prevent_demo_company_conversion();
    SQL
    remove_index :companies, name: "index_demo_companies_on_organization_fixture_key"
    remove_index :companies, name: "index_live_and_demo_companies_on_lower_subdomain_slug"
    remove_check_constraint :companies, name: "company_subdomain_requires_live_payroll"
    add_check_constraint :companies, "subdomain_slug IS NULL OR payroll_environment = 'live'",
                         name: "company_subdomain_requires_live_payroll"

    remove_check_constraint :companies, name: "companies_test_workspace_shape_check"
    add_check_constraint :companies, <<~SQL.squish, name: "companies_test_workspace_shape_check"
      (
        payroll_environment = 'live'
        AND migration_source_company_id IS NULL
        AND migration_source_batch_id IS NULL
        AND migration_rehearsal_status IS NULL
        AND test_workspace_purpose IS NULL
      )
      OR
      (
        payroll_environment = 'migration_rehearsal'
        AND migration_source_company_id IS NOT NULL
        AND migration_rehearsal_status IS NOT NULL
        AND test_workspace_purpose IS NOT NULL
        AND (
          test_workspace_purpose <> 'migration_rehearsal'
          OR migration_source_batch_id IS NOT NULL
        )
      )
    SQL

    remove_check_constraint :companies, name: "companies_test_workspace_purpose_check"
    add_check_constraint :companies,
                         "test_workspace_purpose IS NULL OR test_workspace_purpose IN (#{PURPOSES_WITHOUT_DEMO})",
                         name: "companies_test_workspace_purpose_check"
  end
end
