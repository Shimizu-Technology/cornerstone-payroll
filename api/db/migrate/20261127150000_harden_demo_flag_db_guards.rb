# frozen_string_literal: true

# Track B (Expand phase — dual-shape DB guards):
# 1. Demo identity immutability: extends companies_demo_shape_immutable to watch
#    `demo` as well as legacy columns so validation-skipping writes (update_all /
#    SQL) cannot flip demo from true -> false or false -> true.
# 2. External time-tracking refusal: gives time_tracking_sources its own trigger
#    function refusing BOTH demo = true and legacy test_workspace_purpose = 'demo',
#    while leaving prevent_demo_company_external_records() on legacy-only tables
#    (filing records/events, liability postings/entries, non-employee checks) so
#    lifted workflows work for new-shape demo companies.
# 3. Check supersession rollout predicates: aligns SQL triggers with
#    Company#live_payroll? (payroll_environment = 'live' AND NOT demo) so demo
#    check supersession succeeds without a live rollout approval while real live
#    clients still require one.
class HardenDemoFlagDbGuards < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    install_hardened_demo_guards
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    restore_legacy_demo_guards
  end

  private

  def restore_legacy_demo_guards
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

      DROP TRIGGER IF EXISTS time_tracking_sources_refuse_demo_company ON time_tracking_sources;
      CREATE TRIGGER time_tracking_sources_refuse_demo_company
      BEFORE INSERT OR UPDATE OF company_id ON time_tracking_sources
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_external_records();

      DROP FUNCTION IF EXISTS prevent_demo_company_time_tracking_source();

      CREATE OR REPLACE FUNCTION protect_check_supersession_rollout_approval() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          RAISE EXCEPTION 'Check supersession rollout approvals are append-only';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM companies c JOIN users u ON u.id = NEW.approved_by_id
          WHERE c.id = NEW.company_id AND c.payroll_environment = 'live'
            AND u.organization_id = c.organization_id AND u.active = true
            AND u.role IN (5, 6)
        ) OR length(btrim(NEW.reason)) < 20 THEN
          RAISE EXCEPTION 'Live-check rollout approval requires an active organization administrator and documented reason';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE OR REPLACE FUNCTION enforce_check_supersession_rollout_approval() RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM companies c JOIN users u ON u.id = NEW.user_id
          WHERE c.id = NEW.company_id AND u.organization_id = c.organization_id
            AND u.active = true AND u.role IN (5, 6, 0, 1)
        ) THEN
          RAISE EXCEPTION 'Check supersession requires an active manager or administrator';
        END IF;
        IF EXISTS (SELECT 1 FROM companies WHERE id = NEW.company_id AND payroll_environment = 'live')
          AND NOT EXISTS (SELECT 1 FROM check_supersession_rollout_approvals WHERE company_id = NEW.company_id) THEN
          RAISE EXCEPTION 'Live-check supersession requires company-specific rollout approval';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  # Keep the current definitions last for the DatabaseIntegrity snapshot spec.
  def install_hardened_demo_guards
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

      CREATE OR REPLACE FUNCTION prevent_demo_company_time_tracking_source() RETURNS trigger AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM companies
          WHERE id = NEW.company_id
            AND (demo = true OR COALESCE(test_workspace_purpose, '') = 'demo')
        ) THEN
          RAISE EXCEPTION '% cannot belong to a demo company', TG_TABLE_NAME
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS time_tracking_sources_refuse_demo_company ON time_tracking_sources;
      CREATE TRIGGER time_tracking_sources_refuse_demo_company
      BEFORE INSERT OR UPDATE OF company_id ON time_tracking_sources
      FOR EACH ROW
      EXECUTE FUNCTION prevent_demo_company_time_tracking_source();

      CREATE OR REPLACE FUNCTION protect_check_supersession_rollout_approval() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          RAISE EXCEPTION 'Check supersession rollout approvals are append-only';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM companies c JOIN users u ON u.id = NEW.approved_by_id
          WHERE c.id = NEW.company_id AND c.payroll_environment = 'live' AND NOT c.demo
            AND u.organization_id = c.organization_id AND u.active = true
            AND u.role IN (5, 6)
        ) OR length(btrim(NEW.reason)) < 20 THEN
          RAISE EXCEPTION 'Live-check rollout approval requires an active organization administrator and documented reason';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE OR REPLACE FUNCTION enforce_check_supersession_rollout_approval() RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM companies c JOIN users u ON u.id = NEW.user_id
          WHERE c.id = NEW.company_id AND u.organization_id = c.organization_id
            AND u.active = true AND u.role IN (5, 6, 0, 1)
        ) THEN
          RAISE EXCEPTION 'Check supersession requires an active manager or administrator';
        END IF;
        IF EXISTS (SELECT 1 FROM companies WHERE id = NEW.company_id AND payroll_environment = 'live' AND NOT demo)
          AND NOT EXISTS (SELECT 1 FROM check_supersession_rollout_approvals WHERE company_id = NEW.company_id) THEN
          RAISE EXCEPTION 'Live-check supersession requires company-specific rollout approval';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end
