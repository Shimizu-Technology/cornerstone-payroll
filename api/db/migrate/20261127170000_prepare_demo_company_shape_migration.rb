# frozen_string_literal: true

require_relative "support/demo_shape_migration_functions"

# Track B (Pre-conversion dual-shape DB preparation):
# Safe to deploy BEFORE any existing demo company is converted. Performs no
# data migration on deploy.
#
# 1. Makes fk_employee_account_links_live_company DEFERRABLE INITIALLY IMMEDIATE
#    so the owner-only conversion/revert functions can atomically update a demo
#    company and its employee_account_links in one transaction without dropping
#    the FK or taking table-wide exclusive locks. Normal statements keep
#    immediate enforcement.
# 2. Installs owner-only SECURITY DEFINER functions
#    convert_demo_company_to_flag(...) and revert_demo_company_to_legacy_shape(...)
#    with EXECUTE revoked from PUBLIC and never granted to payroll_app.
# 3. Hardens prevent_demo_company_conversion() with NULL-safe logic, an owner
#    role boundary (payroll_app cannot assert the transition even after setting
#    the GUC), and strict manifest + demo_fixture_key immutability (a keyless
#    demo cannot acquire a key and no manifest field can change during shape
#    migration).
class PrepareDemoCompanyShapeMigration < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    execute <<~SQL
      ALTER TABLE employee_account_links
        ALTER CONSTRAINT fk_employee_account_links_live_company DEFERRABLE INITIALLY IMMEDIATE;
    SQL
    execute DemoShapeMigrationFunctions.schema_sql(current_schema)
    install_migration_ready_demo_guards
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    restore_previous_demo_guards
    execute "DROP FUNCTION IF EXISTS #{DemoShapeMigrationFunctions.qualified_convert_signature(current_schema)};"
    execute "DROP FUNCTION IF EXISTS #{DemoShapeMigrationFunctions.qualified_revert_signature(current_schema)};"
    execute <<~SQL
      ALTER TABLE employee_account_links
        ALTER CONSTRAINT fk_employee_account_links_live_company NOT DEFERRABLE;
    SQL
  end

  private

  def current_schema
    select_value("SELECT current_schema()")
  end

  def restore_previous_demo_guards
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_demo_company_conversion() RETURNS trigger AS $$
      DECLARE
        old_is_demo boolean := OLD.demo OR COALESCE(OLD.test_workspace_purpose, '') = 'demo';
      BEGIN
        IF OLD.demo IS DISTINCT FROM NEW.demo
          OR (COALESCE(OLD.test_workspace_purpose, '') = 'demo') <> (COALESCE(NEW.test_workspace_purpose, '') = 'demo')
          OR (old_is_demo AND OLD.payroll_environment IS DISTINCT FROM NEW.payroll_environment) THEN
          RAISE EXCEPTION 'demo companies cannot be converted to or from another company type'
            USING ERRCODE = 'check_violation';
        END IF;
        IF old_is_demo
          AND (OLD.test_workspace_manifest ->> 'demo_fixture_key') IS NOT NULL
          AND (OLD.test_workspace_manifest ->> 'demo_fixture_key') IS DISTINCT FROM (NEW.test_workspace_manifest ->> 'demo_fixture_key') THEN
          RAISE EXCEPTION 'demo fixture keys are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS companies_demo_shape_immutable ON companies;
      CREATE TRIGGER companies_demo_shape_immutable
      BEFORE UPDATE OF demo, payroll_environment, test_workspace_purpose, test_workspace_manifest ON companies
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_conversion();
    SQL
  end

  # Keep the current definitions last for the DatabaseIntegrity snapshot spec.
  def install_migration_ready_demo_guards
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_demo_company_conversion() RETURNS trigger AS $$
      DECLARE
        old_is_demo boolean := COALESCE(OLD.demo, false) OR COALESCE(OLD.test_workspace_purpose, '') = 'demo';
        old_is_legacy_demo boolean := NOT COALESCE(OLD.demo, false)
          AND OLD.payroll_environment = 'migration_rehearsal'
          AND COALESCE(OLD.test_workspace_purpose, '') = 'demo'
          AND OLD.migration_source_company_id IS NULL
          AND OLD.migration_source_batch_id IS NULL
          AND OLD.test_workspace_expires_at IS NULL
          AND OLD.test_workspace_archived_at IS NULL
          AND OLD.test_workspace_sealed_at IS NULL;
        new_is_flag_demo boolean := NEW.demo IS TRUE
          AND NEW.payroll_environment = 'live'
          AND NEW.test_workspace_purpose IS NULL
          AND NEW.migration_rehearsal_status IS NULL
          AND NEW.migration_source_company_id IS NULL
          AND NEW.migration_source_batch_id IS NULL
          AND NEW.migration_rehearsal_created_by_id IS NULL
          AND NEW.migration_rehearsal_created_at IS NULL
          AND NEW.migration_rehearsal_completed_at IS NULL
          AND NEW.migration_rehearsal_error IS NULL
          AND NEW.test_workspace_expires_at IS NULL
          AND NEW.test_workspace_archived_at IS NULL
          AND NEW.test_workspace_sealed_at IS NULL;
        old_is_flag_demo boolean := OLD.demo IS TRUE
          AND OLD.payroll_environment = 'live'
          AND OLD.test_workspace_purpose IS NULL;
        new_is_legacy_demo boolean := NEW.demo IS FALSE
          AND NEW.payroll_environment = 'migration_rehearsal'
          AND COALESCE(NEW.test_workspace_purpose, '') = 'demo'
          AND NEW.migration_rehearsal_status = 'ready'
          AND NEW.migration_source_company_id IS NULL
          AND NEW.migration_source_batch_id IS NULL
          AND NEW.test_workspace_expires_at IS NULL
          AND NEW.test_workspace_archived_at IS NULL
          AND NEW.test_workspace_sealed_at IS NULL;
        caller_is_owner boolean := COALESCE(
          pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid = TG_RELID), 'USAGE')
          AND pg_has_role(session_user, (SELECT relowner FROM pg_class WHERE oid = TG_RELID), 'USAGE'),
          false
        );
        migration_op text := COALESCE(current_setting('app.demo_shape_migration_op', true), '');
        manifest_unchanged boolean := OLD.test_workspace_manifest IS NOT DISTINCT FROM NEW.test_workspace_manifest;
        converting_legacy_demo boolean := COALESCE(
          caller_is_owner AND migration_op = 'convert' AND old_is_legacy_demo AND new_is_flag_demo AND manifest_unchanged,
          false
        );
        reverting_flag_demo boolean := COALESCE(
          caller_is_owner AND migration_op = 'revert' AND old_is_flag_demo AND new_is_legacy_demo AND manifest_unchanged,
          false
        );
      BEGIN
        IF NOT (converting_legacy_demo OR reverting_flag_demo) AND (
          OLD.demo IS DISTINCT FROM NEW.demo
          OR (COALESCE(OLD.test_workspace_purpose, '') = 'demo') <> (COALESCE(NEW.test_workspace_purpose, '') = 'demo')
          OR (old_is_demo AND OLD.payroll_environment IS DISTINCT FROM NEW.payroll_environment)
        ) THEN
          RAISE EXCEPTION 'demo companies cannot be converted to or from another company type'
            USING ERRCODE = 'check_violation';
        END IF;
        IF old_is_demo
          AND (OLD.test_workspace_manifest ->> 'demo_fixture_key') IS DISTINCT FROM (NEW.test_workspace_manifest ->> 'demo_fixture_key') THEN
          RAISE EXCEPTION 'demo fixture keys are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
        IF (converting_legacy_demo OR reverting_flag_demo)
          AND OLD.test_workspace_manifest IS DISTINCT FROM NEW.test_workspace_manifest THEN
          RAISE EXCEPTION 'demo manifest cannot change during shape migration'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS companies_demo_shape_immutable ON companies;
      CREATE TRIGGER companies_demo_shape_immutable
      BEFORE UPDATE OF demo, payroll_environment, test_workspace_purpose, test_workspace_manifest ON companies
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_conversion();
    SQL
  end
end
