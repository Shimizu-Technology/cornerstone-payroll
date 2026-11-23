-- Applied by RlsDatabase.install! as the schema owner.
CREATE OR REPLACE FUNCTION app_current_company_id() RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE
  cid text := nullif(current_setting('app.current_company_id', true), '');
BEGIN
  -- The planner may evaluate the STABLE expression ahead of a policy's OR.
  IF current_setting('app.rls_mode', true) = 'system' THEN
    RETURN NULL;
  END IF;
  IF cid IS NULL THEN
    RAISE EXCEPTION 'RLS context missing: set app.current_company_id or app.rls_mode=system'
      USING ERRCODE = '42501';
  END IF;
  RETURN cid::bigint;
END;
$$;

CREATE SCHEMA IF NOT EXISTS rls_admin;
REVOKE ALL ON SCHEMA rls_admin FROM PUBLIC;
CREATE TABLE IF NOT EXISTS rls_admin.rls_kill_switch (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  bypass_enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reason text
);
INSERT INTO rls_admin.rls_kill_switch (singleton) VALUES (true) ON CONFLICT DO NOTHING;
REVOKE ALL ON rls_admin.rls_kill_switch FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'payroll_app') THEN
    GRANT USAGE ON SCHEMA rls_admin TO payroll_app;
    REVOKE ALL ON rls_admin.rls_kill_switch FROM payroll_app;
    GRANT SELECT ON rls_admin.rls_kill_switch TO payroll_app;
  END IF;
END;
$$;

-- The installer calls this temporary function for every registered protected
-- table. The same predicate protects reads, updates, deletes and writes.
CREATE OR REPLACE FUNCTION pg_temp.install_company_policy(
  target_schema text, child_table text, parent_table text DEFAULT NULL, foreign_key text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  condition text;
  company_function text := format('%I.app_current_company_id()', target_schema);
BEGIN
  IF parent_table IS NULL THEN
    condition := format('company_id = %s', company_function);
  ELSE
    condition := format(
      'EXISTS (SELECT 1 FROM %I.%I AS parent WHERE parent.id = %I.%I AND parent.company_id = %s)',
      target_schema, parent_table, child_table, foreign_key, company_function
    );
  END IF;

  condition := format('current_setting(''app.rls_mode'', true) = ''system'' OR (%s)', condition);
  EXECUTE format('DROP POLICY IF EXISTS company_isolation ON %I.%I', target_schema, child_table);
  EXECUTE format(
    'CREATE POLICY company_isolation ON %I.%I USING (%s) WITH CHECK (%s)',
    target_schema, child_table, condition, condition
  );
END;
$$;
