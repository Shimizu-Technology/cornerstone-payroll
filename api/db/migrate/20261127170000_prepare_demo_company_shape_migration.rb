# frozen_string_literal: true

# Track B (Pre-conversion dual-shape DB preparation):
# Safe to deploy BEFORE any existing demo company is converted. Performs no
# data migration on deploy.
#
# 1. Makes fk_employee_account_links_live_company DEFERRABLE INITIALLY IMMEDIATE
#    so the operator-run DemoCompany::ConvertToFlag service can atomically
#    update a demo company and its employee_account_links to
#    payroll_environment = 'live' in one transaction per company (including
#    under the restricted payroll_app role without DDL or table-wide exclusive
#    locks). Normal statements outside an explicit SET CONSTRAINTS ... DEFERRED
#    transaction keep immediate enforcement.
# 2. Updates prevent_demo_company_conversion() so an explicit transaction with
#    SET LOCAL app.allow_demo_shape_migration = 'on' can perform ONLY the exact
#    one-way conversion from an old-shape demo (payroll_environment =
#    'migration_rehearsal', test_workspace_purpose = 'demo', demo = false) to a
#    new-shape demo (payroll_environment = 'live', demo = true, all
#    test-workspace/rehearsal columns NULL) while preserving demo_fixture_key.
#    Every other demo/live/practice conversion remains refused by PostgreSQL.
class PrepareDemoCompanyShapeMigration < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    execute <<~SQL
      ALTER TABLE employee_account_links
        ALTER CONSTRAINT fk_employee_account_links_live_company DEFERRABLE INITIALLY IMMEDIATE;
    SQL
    install_migration_ready_demo_guards
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    restore_previous_demo_guards
    execute <<~SQL
      ALTER TABLE employee_account_links
        ALTER CONSTRAINT fk_employee_account_links_live_company NOT DEFERRABLE;
    SQL
  end

  private

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
        old_is_demo boolean := OLD.demo OR COALESCE(OLD.test_workspace_purpose, '') = 'demo';
        old_is_legacy_demo boolean := NOT OLD.demo
          AND OLD.payroll_environment = 'migration_rehearsal'
          AND COALESCE(OLD.test_workspace_purpose, '') = 'demo';
        new_is_flag_demo boolean := NEW.demo = true
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
        converting_legacy_demo boolean := current_setting('app.allow_demo_shape_migration', true) = 'on'
          AND old_is_legacy_demo
          AND new_is_flag_demo;
      BEGIN
        IF NOT converting_legacy_demo AND (
          OLD.demo IS DISTINCT FROM NEW.demo
          OR (COALESCE(OLD.test_workspace_purpose, '') = 'demo') <> (COALESCE(NEW.test_workspace_purpose, '') = 'demo')
          OR (old_is_demo AND OLD.payroll_environment IS DISTINCT FROM NEW.payroll_environment)
        ) THEN
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
end
