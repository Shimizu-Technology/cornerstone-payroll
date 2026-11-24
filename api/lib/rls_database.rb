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

  SWITCH_CACHE = Concurrent::AtomicReference.new

  LOGIN_LINK_DECISION = "payroll_employee_login_link_decision(bigint, bigint, bigint[])"
  # Read-only facts about the cross-company login link decision function.
  # The owner must bypass RLS to see every company; PUBLIC must not execute it.
  LOGIN_LINK_DECISION_STATUS = <<~SQL.squish.freeze
    SELECT p.prosecdef AS security_definer, p.provolatile = 's' AS stable,
           coalesce('search_path=pg_catalog, public' = ANY (p.proconfig), false) AS search_path_pinned,
           (o.rolbypassrls OR o.rolsuper) AS owner_bypasses_rls,
           EXISTS (SELECT FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                   WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE') AS public_can_execute,
           (SELECT has_function_privilege(r.oid, p.oid, 'EXECUTE') FROM pg_roles r WHERE r.rolname = 'payroll_app') AS runtime_can_execute
    FROM pg_proc p JOIN pg_roles o ON o.oid = p.proowner
    WHERE p.oid = to_regprocedure('#{LOGIN_LINK_DECISION}')
  SQL

  def self.install!(connection)
    schema = connection.select_value("SELECT current_schema()")
    connection.transaction do
      connection.execute("SET LOCAL lock_timeout = '3s'")
      connection.execute(File.read(POLICY_FILE))
    end
    RlsTables::PROTECTED_TABLES.each do |table|
      parent, foreign_key = RlsTables::RLS_PARENT_PROTECTED_TABLES[table]
      shared_read = RlsTables::RLS_SHARED_READ_TABLES.include?(table)
      args = [ schema, table, parent, foreign_key, shared_read ].map { |value| connection.quote(value) }.join(", ")
      connection.transaction do
        connection.execute("SET LOCAL lock_timeout = '3s'")
        connection.execute("SELECT pg_temp.install_company_policy(#{args})")
      end
    end
  end

  def self.verify_runtime!(connection)
    return true if connection.select_value(ROLE_CHECK) == true

    raise "RLS runtime must use the non-bypass payroll_app role with SELECT-only access to #{SWITCH}"
  end

  def self.table_status(connection)
    names = RlsTables::PROTECTED_TABLES.map { |table| connection.quote(table) }.join(", ")
    shared = RlsTables::RLS_SHARED_READ_TABLES.map { |table| connection.quote(table) }.join(", ")
    connection.select_all(<<~SQL).to_a
      SELECT c.relname AS table, c.relrowsecurity AS enabled, c.relforcerowsecurity AS forced,
             (SELECT coalesce(array_agg(polname::text || ':' || polcmd::text ORDER BY polname), ARRAY[]::text[])
              FROM pg_policy WHERE polrelid = c.oid) =
              CASE WHEN c.relname IN (#{shared})
                THEN ARRAY['company_delete:d', 'company_insert:a', 'company_select:r', 'company_update:w']
                ELSE ARRAY['company_isolation:*']
              END AS policy
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

  def self.login_link_decision_status(connection)
    row = connection.select_one(LOGIN_LINK_DECISION_STATUS)
    return { "installed" => false } unless row

    { "installed" => true }.merge(row)
  end

  # runtime_can_execute is nil where no payroll_app role exists yet.
  def self.login_link_decision_ready?(connection)
    status = login_link_decision_status(connection)
    status.values_at("installed", "security_definer", "stable", "search_path_pinned", "owner_bypasses_rls").all?(true) &&
      status["public_can_execute"] == false && status["runtime_can_execute"] != false
  end

  def self.bypass_enabled?(connection)
    # Tests can exercise the switch explicitly. Production consults the
    # durable switch only after the direct runtime URL has been configured.
    return false unless RlsConfiguration.runtime_url

    cached = SWITCH_CACHE.get
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return cached.first if cached && now < cached.last

    enabled = connection.select_value("SELECT bypass_enabled FROM #{SWITCH} WHERE singleton") == true
    SWITCH_CACHE.compare_and_set(cached, [ enabled, now + 5 ].freeze)
    SWITCH_CACHE.get.first
  end
end
