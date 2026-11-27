# frozen_string_literal: true

require "pg"

# Owner-only SECURITY DEFINER helpers for the Track B demo-shape migration and
# its targeted per-company rollback.
#
# Privileges:
# - REVOKE ALL FROM PUBLIC (and explicitly from payroll_app when present) on
#   both functions and on `demo_shape_conversions`.
# - Never granted to payroll_app; only the migration/table-owner role can
#   execute them.
# - Each function verifies pg_has_role(session_user, companies_owner, 'USAGE')
#   before setting the transaction-local app.demo_shape_migration_op flag and
#   running the exact shape update, then clears the flag before returning.
# - `convert_demo_company_to_flag` records the exact pre-conversion company
#   shape, link environments, and post-conversion shape in the append-only
#   `demo_shape_conversions` table and returns the conversion ID.
# - `revert_demo_company_to_legacy_shape` accepts ONLY a recorded conversion ID
#   (never free-form external metadata), requires WriteMaintenance to be
#   asserted (`p_write_maintenance IS TRUE`), locks the company row `FOR UPDATE`
#   (serializing with `prevent_demo_company_external_records()`'s `FOR KEY SHARE`
#   lock), verifies the conversion has not already been reverted and the company's
#   current shape matches what the conversion wrote, restores the exact recorded
#   before-state, and marks the conversion reverted.
module DemoShapeMigrationFunctions
  CONVERT_NAME = "convert_demo_company_to_flag"
  CONVERT_ARGS = "(bigint, bigint, timestamp with time zone)"
  CONVERT_SIGNATURE = "#{CONVERT_NAME}#{CONVERT_ARGS}".freeze

  REVERT_NAME = "revert_demo_company_to_legacy_shape"
  REVERT_ARGS = "(bigint, bigint, boolean, timestamp with time zone)"
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
      CREATE OR REPLACE FUNCTION #{CONVERT_NAME}(
        p_company_id bigint,
        p_actor_id bigint,
        p_updated_at timestamp with time zone
      )
      RETURNS bigint
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = pg_catalog, #{target}, pg_temp
      SET row_security = off
      AS $$
      DECLARE
        v_owner oid;
        v_company #{target}.companies%ROWTYPE;
        v_before_company jsonb;
        v_before_links jsonb;
        v_after_company jsonb;
        v_conversion_id bigint;
      BEGIN
        SELECT relowner INTO v_owner FROM pg_class WHERE oid = '#{target}.companies'::regclass;
        IF NOT COALESCE(pg_has_role(session_user, v_owner, 'USAGE'), false) THEN
          RAISE EXCEPTION 'demo shape conversion requires the table owner role'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        SELECT * INTO v_company
        FROM #{target}.companies
        WHERE id = p_company_id
        FOR UPDATE;

        IF NOT FOUND
          OR v_company.demo IS NOT FALSE
          OR v_company.payroll_environment IS DISTINCT FROM 'migration_rehearsal'
          OR COALESCE(v_company.test_workspace_purpose, '') <> 'demo'
          OR v_company.migration_source_company_id IS NOT NULL
          OR v_company.migration_source_batch_id IS NOT NULL
          OR v_company.test_workspace_expires_at IS NOT NULL
          OR v_company.test_workspace_archived_at IS NOT NULL
          OR v_company.test_workspace_sealed_at IS NOT NULL THEN
          RAISE EXCEPTION 'company % is not an old-shape demo company', p_company_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM #{target}.demo_shape_conversions
          WHERE company_id = p_company_id AND reverted_at IS NULL
        ) THEN
          RAISE EXCEPTION 'company % already has an active demo shape conversion record', p_company_id
            USING ERRCODE = 'check_violation';
        END IF;

        PERFORM id
        FROM #{target}.employee_account_links
        WHERE company_id = p_company_id
        ORDER BY id
        FOR UPDATE;

        SELECT COALESCE(jsonb_object_agg(id::text, payroll_environment), '{}'::jsonb)
        INTO v_before_links
        FROM #{target}.employee_account_links
        WHERE company_id = p_company_id;

        v_before_company := jsonb_build_object(
          'demo', v_company.demo,
          'payroll_environment', v_company.payroll_environment,
          'test_workspace_purpose', v_company.test_workspace_purpose,
          'migration_rehearsal_status', v_company.migration_rehearsal_status,
          'migration_rehearsal_created_by_id', v_company.migration_rehearsal_created_by_id,
          'migration_rehearsal_created_at', v_company.migration_rehearsal_created_at,
          'migration_rehearsal_completed_at', v_company.migration_rehearsal_completed_at,
          'migration_rehearsal_error', v_company.migration_rehearsal_error,
          'migration_source_company_id', v_company.migration_source_company_id,
          'migration_source_batch_id', v_company.migration_source_batch_id,
          'test_workspace_expires_at', v_company.test_workspace_expires_at,
          'test_workspace_archived_at', v_company.test_workspace_archived_at,
          'test_workspace_sealed_at', v_company.test_workspace_sealed_at,
          'test_workspace_manifest', v_company.test_workspace_manifest
        );

        v_after_company := jsonb_build_object(
          'demo', true,
          'payroll_environment', 'live',
          'test_workspace_purpose', NULL,
          'migration_rehearsal_status', NULL,
          'migration_rehearsal_created_by_id', NULL,
          'migration_rehearsal_created_at', NULL,
          'migration_rehearsal_completed_at', NULL,
          'migration_rehearsal_error', NULL,
          'migration_source_company_id', NULL,
          'migration_source_batch_id', NULL,
          'test_workspace_expires_at', NULL,
          'test_workspace_archived_at', NULL,
          'test_workspace_sealed_at', NULL,
          'test_workspace_manifest', v_company.test_workspace_manifest
        );

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
        WHERE id = p_company_id;

        UPDATE #{target}.employee_account_links
        SET payroll_environment = 'live',
            updated_at = p_updated_at
        WHERE company_id = p_company_id
          AND payroll_environment <> 'live';

        SET CONSTRAINTS #{target}.fk_employee_account_links_live_company IMMEDIATE;

        INSERT INTO #{target}.demo_shape_conversions (
          organization_id,
          company_id,
          actor_id,
          before_company_shape,
          before_link_environments,
          after_company_shape,
          converted_at,
          created_at,
          updated_at
        ) VALUES (
          v_company.organization_id,
          v_company.id,
          p_actor_id,
          v_before_company,
          v_before_links,
          v_after_company,
          p_updated_at,
          p_updated_at,
          p_updated_at
        )
        RETURNING id INTO v_conversion_id;

        PERFORM set_config('app.demo_shape_migration_op', '', true);
        RETURN v_conversion_id;
      END;
      $$;
      REVOKE ALL ON FUNCTION #{qualified_convert_signature(schema)} FROM PUBLIC;

      CREATE OR REPLACE FUNCTION #{REVERT_NAME}(
        p_conversion_id bigint,
        p_reverted_by_id bigint,
        p_write_maintenance boolean,
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
        v_conv #{target}.demo_shape_conversions%ROWTYPE;
        v_company #{target}.companies%ROWTYPE;
        v_links_updated integer := 0;
        v_expected_manifest jsonb;
        v_before_status text;
        v_before_created_by_id bigint;
        v_before_created_at timestamp with time zone;
        v_before_completed_at timestamp with time zone;
        v_before_error text;
      BEGIN
        SELECT relowner INTO v_owner FROM pg_class WHERE oid = '#{target}.companies'::regclass;
        IF NOT COALESCE(pg_has_role(session_user, v_owner, 'USAGE'), false) THEN
          RAISE EXCEPTION 'demo shape revert requires the table owner role'
            USING ERRCODE = 'insufficient_privilege';
        END IF;

        IF p_write_maintenance IS NOT TRUE THEN
          RAISE EXCEPTION 'demo shape revert requires WriteMaintenance to be enabled'
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT * INTO v_conv
        FROM #{target}.demo_shape_conversions
        WHERE id = p_conversion_id
        FOR UPDATE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'demo shape conversion % not found', p_conversion_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF v_conv.reverted_at IS NOT NULL THEN
          RAISE EXCEPTION 'demo shape conversion % has already been reverted', p_conversion_id
            USING ERRCODE = 'check_violation';
        END IF;

        SELECT * INTO v_company
        FROM #{target}.companies
        WHERE id = v_conv.company_id
        FOR UPDATE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'company % for conversion % not found', v_conv.company_id, p_conversion_id
            USING ERRCODE = 'check_violation';
        END IF;

        v_expected_manifest := v_conv.after_company_shape -> 'test_workspace_manifest';
        IF v_company.demo IS NOT TRUE
          OR v_company.payroll_environment IS DISTINCT FROM 'live'
          OR v_company.test_workspace_purpose IS NOT NULL
          OR v_company.migration_rehearsal_status IS NOT NULL
          OR v_company.migration_rehearsal_created_by_id IS NOT NULL
          OR v_company.migration_rehearsal_created_at IS NOT NULL
          OR v_company.migration_rehearsal_completed_at IS NOT NULL
          OR v_company.migration_rehearsal_error IS NOT NULL
          OR v_company.migration_source_company_id IS NOT NULL
          OR v_company.migration_source_batch_id IS NOT NULL
          OR v_company.test_workspace_expires_at IS NOT NULL
          OR v_company.test_workspace_archived_at IS NOT NULL
          OR v_company.test_workspace_sealed_at IS NOT NULL
          OR v_company.test_workspace_manifest IS DISTINCT FROM v_expected_manifest THEN
          RAISE EXCEPTION 'company % current shape differs from recorded conversion %', v_conv.company_id, p_conversion_id
            USING ERRCODE = 'check_violation';
        END IF;

        v_before_status := v_conv.before_company_shape ->> 'migration_rehearsal_status';
        IF COALESCE(v_conv.before_company_shape ->> 'demo', '') <> 'false'
          OR COALESCE(v_conv.before_company_shape ->> 'payroll_environment', '') <> 'migration_rehearsal'
          OR COALESCE(v_conv.before_company_shape ->> 'test_workspace_purpose', '') <> 'demo'
          OR v_before_status IS DISTINCT FROM 'ready' THEN
          RAISE EXCEPTION 'conversion % does not record a valid legacy demo before-state', p_conversion_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF EXISTS (SELECT 1 FROM #{target}.payroll_filing_records WHERE company_id = v_conv.company_id)
          OR EXISTS (SELECT 1 FROM #{target}.payroll_filing_events WHERE company_id = v_conv.company_id)
          OR EXISTS (SELECT 1 FROM #{target}.payroll_liability_postings WHERE company_id = v_conv.company_id)
          OR EXISTS (SELECT 1 FROM #{target}.payroll_liability_entries WHERE company_id = v_conv.company_id)
          OR EXISTS (SELECT 1 FROM #{target}.non_employee_checks WHERE company_id = v_conv.company_id) THEN
          RAISE EXCEPTION 'company % has post-conversion filing, liability, or non-employee check rows and cannot revert to legacy shape', v_conv.company_id
            USING ERRCODE = 'check_violation';
        END IF;

        PERFORM id
        FROM #{target}.employee_account_links
        WHERE company_id = v_conv.company_id
        ORDER BY id
        FOR UPDATE;

        IF EXISTS (
          SELECT 1 FROM #{target}.employee_account_links
          WHERE company_id = v_conv.company_id AND payroll_environment <> 'live'
        ) THEN
          RAISE EXCEPTION 'company % employee_account_links differ from converted live shape', v_conv.company_id
            USING ERRCODE = 'check_violation';
        END IF;

        v_before_created_by_id := NULLIF(v_conv.before_company_shape ->> 'migration_rehearsal_created_by_id', '')::bigint;
        v_before_created_at := NULLIF(v_conv.before_company_shape ->> 'migration_rehearsal_created_at', '')::timestamp with time zone;
        v_before_completed_at := NULLIF(v_conv.before_company_shape ->> 'migration_rehearsal_completed_at', '')::timestamp with time zone;
        v_before_error := v_conv.before_company_shape ->> 'migration_rehearsal_error';

        PERFORM set_config('app.demo_shape_migration_op', 'revert', true);
        SET CONSTRAINTS #{target}.fk_employee_account_links_live_company DEFERRED;

        UPDATE #{target}.companies
        SET demo = false,
            payroll_environment = 'migration_rehearsal',
            test_workspace_purpose = 'demo',
            migration_rehearsal_status = v_before_status,
            migration_rehearsal_created_by_id = v_before_created_by_id,
            migration_rehearsal_created_at = v_before_created_at,
            migration_rehearsal_completed_at = v_before_completed_at,
            migration_rehearsal_error = v_before_error,
            migration_source_company_id = NULL,
            migration_source_batch_id = NULL,
            test_workspace_expires_at = NULL,
            test_workspace_archived_at = NULL,
            test_workspace_sealed_at = NULL,
            updated_at = p_updated_at
        WHERE id = v_conv.company_id;

        UPDATE #{target}.employee_account_links
        SET payroll_environment = COALESCE(v_conv.before_link_environments ->> id::text, 'migration_rehearsal'),
            updated_at = p_updated_at
        WHERE company_id = v_conv.company_id
          AND payroll_environment IS DISTINCT FROM COALESCE(v_conv.before_link_environments ->> id::text, 'migration_rehearsal');
        GET DIAGNOSTICS v_links_updated = ROW_COUNT;

        SET CONSTRAINTS #{target}.fk_employee_account_links_live_company IMMEDIATE;

        UPDATE #{target}.demo_shape_conversions
        SET reverted_at = p_updated_at,
            reverted_by_id = p_reverted_by_id,
            updated_at = p_updated_at
        WHERE id = p_conversion_id;

        PERFORM set_config('app.demo_shape_migration_op', '', true);
        RETURN v_links_updated;
      END;
      $$;
      REVOKE ALL ON FUNCTION #{qualified_revert_signature(schema)} FROM PUBLIC;
      REVOKE ALL ON TABLE #{target}.demo_shape_conversions FROM PUBLIC;

      DO $revoke_runtime$
      BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'payroll_app') THEN
          REVOKE ALL ON FUNCTION #{qualified_convert_signature(schema)} FROM payroll_app;
          REVOKE ALL ON FUNCTION #{qualified_revert_signature(schema)} FROM payroll_app;
          REVOKE ALL ON TABLE #{target}.demo_shape_conversions FROM payroll_app;
        END IF;
      END;
      $revoke_runtime$;
    SQL
  end
end
