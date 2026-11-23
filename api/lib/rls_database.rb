# frozen_string_literal: true

require_relative "rls_tables"

module RlsDatabase
  POLICY_FILE = File.expand_path("../db/rls_policies.sql", __dir__)
  SWITCH = "rls_admin.rls_kill_switch"
  ROLE_CHECK = <<~SQL.squish.freeze
    SELECT current_user = 'payroll_app' AND NOT rolbypassrls AND NOT rolsuper
      AND has_table_privilege(current_user, '#{SWITCH}', 'SELECT')
      AND NOT has_table_privilege(current_user, '#{SWITCH}', 'INSERT,UPDATE,DELETE,TRUNCATE')
    FROM pg_roles WHERE rolname = current_user
  SQL

  @switch_lock = Mutex.new

  def self.install!(connection)
    schema = connection.select_value("SELECT current_schema()")
    connection.transaction do
      connection.execute("SET LOCAL lock_timeout = '3s'")
      connection.execute(File.read(POLICY_FILE))
      policies = RlsTables::PROTECTED_TABLES.map do |table|
        parent, foreign_key = RlsTables::RLS_PARENT_PROTECTED_TABLES[table]
        args = [ schema, table, parent, foreign_key ].map { |value| connection.quote(value) }.join(", ")
        "SELECT pg_temp.install_company_policy(#{args})"
      end
      connection.execute(policies.join(";\n"))
    end
  end

  def self.verify_runtime!(connection)
    return true if connection.select_value(ROLE_CHECK) == true

    raise "RLS runtime must use the non-bypass payroll_app role with SELECT-only access to #{SWITCH}"
  end

  def self.table_status(connection)
    names = RlsTables::PROTECTED_TABLES.map { |table| connection.quote(table) }.join(", ")
    connection.select_all(<<~SQL).to_a
      SELECT c.relname AS table, c.relrowsecurity AS enabled, c.relforcerowsecurity AS forced,
             EXISTS (SELECT FROM pg_policy WHERE polrelid = c.oid AND polname = 'company_isolation') AS policy
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema() AND c.relname IN (#{names})
      ORDER BY c.relname
    SQL
  end

  def self.expected_phase?(connection, enforced:)
    tables = table_status(connection)
    tables.size == RlsTables::PROTECTED_TABLES.size && tables.all? do |row|
      row.fetch("policy") && row.fetch("enabled") == enforced && row.fetch("forced") == enforced
    end
  end

  def self.bypass_enabled?(connection)
    # Tests can exercise the switch explicitly. Production consults the
    # durable switch only after the direct runtime URL has been configured.
    return false unless RlsConfiguration.runtime_url

    @switch_lock.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if !@switch_expires_at || now >= @switch_expires_at
        @bypass_enabled = connection.select_value("SELECT bypass_enabled FROM #{SWITCH} WHERE singleton") == true
        @switch_expires_at = now + 5
      end
      @bypass_enabled
    end
  end
end
