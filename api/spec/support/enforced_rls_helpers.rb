# frozen_string_literal: true

require "stringio"

module EnforcedRlsHelpers
  def enforce_as_runtime_role!
    TenantScope.as_system(reason: "Rehearse phase 3 enforcement") do
      # Enforce RLS before GRANT ... ON ALL TABLES. GRANT updates pg_class for
      # every table without locking the tables themselves; doing it first inside
      # an open transaction lets autovacuum/autoanalyze hold
      # ShareUpdateExclusiveLock on a table while waiting for ShareLock on our
      # transaction to update pg_class, deadlocking when ALTER TABLE later
      # requests AccessExclusiveLock on that table.
      previous_lock_timeout = connection.select_value("SHOW lock_timeout")
      failed = RlsEnforcement.enforce!(connection, RlsEnforcement.ordered_tables, out: StringIO.new)
      connection.execute("SET LOCAL lock_timeout = #{connection.quote(previous_lock_timeout)}")
      expect(failed).to be_empty

      # Roles are cluster-wide; a local cluster may already have one.
      connection.execute(<<~SQL)
        DO $$ BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'payroll_app') THEN
            CREATE ROLE payroll_app NOSUPERUSER NOBYPASSRLS;
          END IF;
        END $$
      SQL
      connection.execute("GRANT USAGE ON SCHEMA public, rls_admin TO payroll_app")
      connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO payroll_app")
      connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO payroll_app")
      connection.execute("GRANT EXECUTE ON FUNCTION #{RlsDatabase::LOGIN_LINK_DECISION} TO payroll_app")
      connection.execute("GRANT SELECT ON #{RlsDatabase::SWITCH} TO payroll_app")
    end
    expect(RlsDatabase.enforcement_summary(connection)).to include("phase" => "enforced", "enforced_tables" => RlsTables::PROTECTED_TABLES.size)
    connection.execute("SET LOCAL ROLE payroll_app")
    expect(RlsDatabase.verify_runtime!(connection)).to be(true)
  end
end
