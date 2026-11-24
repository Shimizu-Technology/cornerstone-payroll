# frozen_string_literal: true

require "pg"

# A narrow, RLS-safe answer to "does this login still have an eligible
# employee link anywhere, other than the one being closed?", for deciding at
# once whether closing a link ends an employee-only login (M4-2, D12).
#
# Eligible means usable right now: active, or former with access still
# running at p_now. Unlike payroll_employee_login_link_decision, an expired
# former link or an unfinished invite elsewhere doesn't count, so it can't
# hold a login open until the daily sweep.
#
# Same safety shape as LoginLinkDecisionFunction: SECURITY DEFINER owned by
# the migration role, row_security = off so lost BYPASSRLS fails closed,
# search_path pinned, every reference qualified to the installed schema, and
# only a boolean comes back. Inside a company scope it answers only about
# logins with a link at that company; any other login gets false.
module LoginEligibleLinkFunction
  NAME = "payroll_employee_login_has_eligible_link"
  ARGUMENTS = "(bigint, bigint, timestamp with time zone)"
  SIGNATURE = "#{NAME}#{ARGUMENTS}".freeze

  def self.qualified_signature(schema)
    "#{PG::Connection.quote_ident(schema)}.#{SIGNATURE}"
  end

  def self.schema_sql(schema)
    target = PG::Connection.quote_ident(schema)
    <<~SQL
      CREATE OR REPLACE FUNCTION #{NAME}(p_login_user_id bigint, p_except_link_id bigint, p_now timestamp with time zone)
      RETURNS boolean
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET row_security = off
      AS $$
        SELECT p_login_user_id IS NOT NULL AND p_now IS NOT NULL
          AND (
            nullif(current_setting('app.current_company_id', true), '') IS NULL
            OR EXISTS (
              SELECT 1 FROM #{target}.employee_account_links own
              WHERE own.user_id = p_login_user_id
                AND own.company_id = nullif(current_setting('app.current_company_id', true), '')::bigint
            )
          )
          AND EXISTS (
            SELECT 1 FROM #{target}.employee_account_links l
            WHERE l.user_id = p_login_user_id
              AND (p_except_link_id IS NULL OR l.id <> p_except_link_id)
              AND (l.status = 'active' OR (l.status = 'former' AND l.former_access_until > p_now))
          )
      $$;
      REVOKE ALL ON FUNCTION #{qualified_signature(schema)} FROM PUBLIC;
      DO $grant$
      BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'payroll_app') THEN
          GRANT EXECUTE ON FUNCTION #{qualified_signature(schema)} TO payroll_app;
        END IF;
      END;
      $grant$;
    SQL
  end
end
