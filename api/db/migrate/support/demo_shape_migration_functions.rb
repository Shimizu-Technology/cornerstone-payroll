# frozen_string_literal: true

require "pg"

# Owner-only SECURITY DEFINER helpers for the Track B demo-shape migration and
# its targeted per-company rollback.
#
# Privileges:
# - REVOKE ALL FROM PUBLIC (and explicitly from payroll_app when present).
# - Never granted to payroll_app; only the migration/table-owner role can
#   execute them.
# - Each function also verifies pg_has_role(session_user, companies_owner, 'USAGE')
#   before setting the transaction-local app.demo_shape_migration_op flag and
#   running the exact shape update, then clears the flag before returning.
# - Every table reference is qualified with the installed schema and search_path
#   is pinned to pg_catalog, pg_temp (matching LoginLinkDecisionFunction).
module DemoShapeMigrationFunctions
  CONVERT_NAME = "convert_demo_company_to_flag"
  CONVERT_ARGS = "(bigint, timestamp with time zone)"
  CONVERT_SIGNATURE = "#{CONVERT_NAME}#{CONVERT_ARGS}".freeze

  REVERT_NAME = "revert_demo_company_to_legacy_shape"
  REVERT_ARGS = "(bigint, text, bigint, timestamp with time zone, timestamp with time zone, timestamp with time zone)"
  REVERT_SIGNATURE = "#{REVERT_NAME}#{REVERT_ARGS}".freeze

  def self.qualified_convert_signature(schema)
    "#{PG::Connection.quote_ident(schema)}.#{CONVERT_SIGNATURE}"
  end

  def self.qualified_revert_signature(schema)
    "#{PG::Connection.quote_ident(schema)}.#{REVERT_SIGNATURE}"
  end

  def self.schema_sql(schema)
    target = PG::Connection.quote_ident(schema)
    <<~SQL
      CREATE OR REPLACE FUNCTION #{CONVERT_NAME}(p_company_id bigint, p_updated_at timestamp with time zone)
      RETURNS integer
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = pg_catalog, #{target}, pg_temp
      SET row_security = off
      AS $$
      DECLARE
        v_owner oid;
        v_links_updated integer := 0;
      BEGIN
        SELECT relowner INTO v_owner FROM pg_class WHERE oid = '#{target}.companies'::regclass;
        IF NOT COALESCE(pg_has_role(session_user, v_owner, 'USAGE'), false) THEN
          RAISE EXCEPTION 'demo shape conversion requires the table owner role'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        PERFORM set_config('app.demo_shape_migration_op', 'convert', true);
        SET CONSTRAINTS #{target}.fk_employee_account_links_live_company DEFERRED;

        UPDATE #{target}.companies
        SET demo = true,
            payroll_environment = 'live',
            test_workspace_purpose = NULL,
            migration_rehearsal_status = NULL,
            migration_rehearsal_created_by_id = NULL,
            migration_rehearsal_created_at = NULL,
            migration_rehearsal_completed_at = NULL,
            migration_rehearsal_error = NULL,
            migration_source_company_id = NULL,
            migration_source_batch_id = NULL,
            test_workspace_expires_at = NULL,
            test_workspace_archived_at = NULL,
            test_workspace_sealed_at = NULL,
            updated_at = p_updated_at
        WHERE id = p_company_id
          AND demo = false
          AND payroll_environment = 'migration_rehearsal'
          AND COALESCE(test_workspace_purpose, '') = 'demo';

        IF NOT FOUND THEN
          PERFORM set_config('app.demo_shape_migration_op', '', true);
          RAISE EXCEPTION 'company % is not an old-shape demo company', p_company_id
            USING ERRCODE = 'check_violation';
        END IF;

        UPDATE #{target}.employee_account_links
        SET payroll_environment = 'live',
            updated_at = p_updated_at
        WHERE company_id = p_company_id
          AND payroll_environment <> 'live';
        GET DIAGNOSTICS v_links_updated = ROW_COUNT;

        SET CONSTRAINTS #{target}.fk_employee_account_links_live_company IMMEDIATE;
        PERFORM set_config('app.demo_shape_migration_op', '', true);
        RETURN v_links_updated;
      END;
      $$;
      REVOKE ALL ON FUNCTION #{qualified_convert_signature(schema)} FROM PUBLIC;

      CREATE OR REPLACE FUNCTION #{REVERT_NAME}(
        p_company_id bigint,
        p_migration_rehearsal_status text,
        p_migration_rehearsal_created_by_id bigint,
        p_migration_rehearsal_created_at timestamp with time zone,
        p_migration_rehearsal_completed_at timestamp with time zone,
        p_updated_at timestamp with time zone
      )
      RETURNS integer
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = pg_catalog, #{target}, pg_temp
      SET row_security = off
      AS $$
      DECLARE
        v_owner oid;
        v_links_updated integer := 0;
      BEGIN
        SELECT relowner INTO v_owner FROM pg_class WHERE oid = '#{target}.companies'::regclass;
        IF NOT COALESCE(pg_has_role(session_user, v_owner, 'USAGE'), false) THEN
          RAISE EXCEPTION 'demo shape revert requires the table owner role'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        IF p_migration_rehearsal_status IS DISTINCT FROM 'ready' THEN
          RAISE EXCEPTION 'demo shape revert requires migration_rehearsal_status = ready'
            USING ERRCODE = 'check_violation';
        END IF;

        IF EXISTS (SELECT 1 FROM #{target}.payroll_filing_records WHERE company_id = p_company_id)
          OR EXISTS (SELECT 1 FROM #{target}.payroll_filing_events WHERE company_id = p_company_id)
          OR EXISTS (SELECT 1 FROM #{target}.payroll_liability_postings WHERE company_id = p_company_id)
          OR EXISTS (SELECT 1 FROM #{target}.payroll_liability_entries WHERE company_id = p_company_id)
          OR EXISTS (SELECT 1 FROM #{target}.non_employee_checks WHERE company_id = p_company_id) THEN
          RAISE EXCEPTION 'company % has post-conversion filing, liability, or non-employee check rows and cannot revert to legacy shape', p_company_id
            USING ERRCODE = 'check_violation';
        END IF;

        PERFORM set_config('app.demo_shape_migration_op', 'revert', true);
        SET CONSTRAINTS #{target}.fk_employee_account_links_live_company DEFERRED;

        UPDATE #{target}.companies
        SET demo = false,
            payroll_environment = 'migration_rehearsal',
            test_workspace_purpose = 'demo',
            migration_rehearsal_status = p_migration_rehearsal_status,
            migration_rehearsal_created_by_id = p_migration_rehearsal_created_by_id,
            migration_rehearsal_created_at = p_migration_rehearsal_created_at,
            migration_rehearsal_completed_at = p_migration_rehearsal_completed_at,
            migration_rehearsal_error = NULL,
            migration_source_company_id = NULL,
            migration_source_batch_id = NULL,
            test_workspace_expires_at = NULL,
            test_workspace_archived_at = NULL,
            test_workspace_sealed_at = NULL,
            updated_at = p_updated_at
        WHERE id = p_company_id
          AND demo = true
          AND payroll_environment = 'live'
          AND test_workspace_purpose IS NULL;

        IF NOT FOUND THEN
          PERFORM set_config('app.demo_shape_migration_op', '', true);
          RAISE EXCEPTION 'company % is not a converted flag-shape demo company', p_company_id
            USING ERRCODE = 'check_violation';
        END IF;

        UPDATE #{target}.employee_account_links
        SET payroll_environment = 'migration_rehearsal',
            updated_at = p_updated_at
        WHERE company_id = p_company_id
          AND payroll_environment <> 'migration_rehearsal';
        GET DIAGNOSTICS v_links_updated = ROW_COUNT;

        SET CONSTRAINTS #{target}.fk_employee_account_links_live_company IMMEDIATE;
        PERFORM set_config('app.demo_shape_migration_op', '', true);
        RETURN v_links_updated;
      END;
      $$;
      REVOKE ALL ON FUNCTION #{qualified_revert_signature(schema)} FROM PUBLIC;

      DO $revoke_runtime$
      BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'payroll_app') THEN
          REVOKE ALL ON FUNCTION #{qualified_convert_signature(schema)} FROM payroll_app;
          REVOKE ALL ON FUNCTION #{qualified_revert_signature(schema)} FROM payroll_app;
        END IF;
      END;
      $revoke_runtime$;
    SQL
  end
end
