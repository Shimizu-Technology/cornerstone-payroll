# frozen_string_literal: true

require "pg"

# A narrow, RLS-safe answer to "is this login linked to another employee?".
#
# Under enforced row-level security a company-scoped session can't see other
# companies' employee_account_links, and TenantScope deliberately refuses a
# nested system read. This SECURITY DEFINER function runs as its owner (the
# migration role, which bypasses RLS), reads across companies, and returns
# only 'allowed', 'conflict' or 'none' - never rows, ids or company details.
# The runtime role may only EXECUTE it.
#
# row_security = off makes PostgreSQL raise instead of silently filtering if
# the owner ever loses BYPASSRLS, so privilege drift fails closed. The
# function lives in, and reads only from, the trusted target schema it was
# installed into; search_path is pinned to pg_catalog and pg_temp.
#
# It mirrors EmployeeAccountLink.contact_email_link_decision: any link that
# isn't revoked counts. 'conflict' when the login links to an employee outside
# p_employee_ids, 'allowed' when every link is to one of them, else 'none'.
# p_employee_ids only count when they belong to p_company_id and, inside a
# company scope, to the session's own company, so the function can't be asked
# about another company's employees.
module LoginLinkDecisionFunction
  NAME = "payroll_employee_login_link_decision"
  ARGUMENTS = "(bigint, bigint, bigint[])"
  SIGNATURE = "#{NAME}#{ARGUMENTS}".freeze

  def self.qualified_signature(schema)
    "#{PG::Connection.quote_ident(schema)}.#{SIGNATURE}"
  end

  # The function is declared unqualified (DatabaseIntegrity matches it by
  # name) and so lands in the installing connection's current schema, which
  # must be the schema passed here; every reference inside is qualified.
  def self.schema_sql(schema)
    target = PG::Connection.quote_ident(schema)
    <<~SQL
      CREATE OR REPLACE FUNCTION #{NAME}(p_login_user_id bigint, p_company_id bigint, p_employee_ids bigint[])
      RETURNS text
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = pg_catalog, pg_temp
      SET row_security = off
      AS $$
        WITH own AS (
          SELECT e.id FROM #{target}.employees e
          WHERE p_company_id IS NOT NULL AND p_employee_ids IS NOT NULL
            AND e.id = ANY (p_employee_ids) AND e.company_id = p_company_id
            AND coalesce(nullif(current_setting('app.current_company_id', true), '')::bigint, p_company_id) = p_company_id
        ), links AS (
          SELECT l.employee_id FROM #{target}.employee_account_links l
          WHERE l.user_id = p_login_user_id AND l.status <> 'revoked'
        )
        SELECT CASE
          WHEN p_login_user_id IS NULL THEN 'none'
          WHEN EXISTS (SELECT 1 FROM links WHERE links.employee_id NOT IN (SELECT own.id FROM own)) THEN 'conflict'
          WHEN EXISTS (SELECT 1 FROM links) THEN 'allowed'
          ELSE 'none'
        END
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
