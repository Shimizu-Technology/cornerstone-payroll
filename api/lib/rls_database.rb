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
  # The owner must bypass RLS to see every company; only the owner and the
  # runtime role may execute it, and nobody else may hold a grant option.
  LOGIN_LINK_DECISION_STATUS = <<~SQL.squish.freeze
    WITH fn AS (
      SELECT p.*, coalesce(p.proacl, acldefault('f', p.proowner)) AS acl
      FROM pg_proc p WHERE p.oid = to_regprocedure('#{LOGIN_LINK_DECISION}')
    )
    SELECT fn.prosecdef AS security_definer, fn.provolatile = 's' AS stable,
           coalesce('search_path=pg_catalog, pg_temp' = ANY (fn.proconfig), false) AS search_path_pinned,
           coalesce('row_security=off' = ANY (fn.proconfig), false) AS row_security_off,
           o.rolname AS owner, (o.rolbypassrls OR o.rolsuper) AS owner_bypasses_rls,
           (SELECT string_agg(g, ',' ORDER BY g) FROM (
              SELECT DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END AS g
              FROM aclexplode(fn.acl) a WHERE a.privilege_type = 'EXECUTE') grantees) AS execute_grantees,
           EXISTS (SELECT FROM aclexplode(fn.acl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE') AS public_can_execute,
           EXISTS (SELECT FROM aclexplode(fn.acl) a WHERE a.is_grantable AND a.grantee <> fn.proowner) AS grant_option_granted,
           (SELECT has_function_privilege(r.oid, fn.oid, 'EXECUTE') FROM pg_roles r WHERE r.rolname = 'payroll_app') AS runtime_can_execute
    FROM fn JOIN pg_roles o ON o.oid = fn.proowner
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

    { "installed" => true }.merge(row).merge("execute_grantees" => row["execute_grantees"].to_s.split(","))
  end

  # The EXECUTE ACL must be exactly the owner plus payroll_app (or just the
  # owner where no runtime role exists yet), with no grant options handed out.
  def self.login_link_decision_ready?(connection)
    status = login_link_decision_status(connection)
    expected = [ status["owner"], ("payroll_app" unless status["runtime_can_execute"].nil?) ].compact.uniq.sort
    status.values_at("installed", "security_definer", "stable", "search_path_pinned", "row_security_off", "owner_bypasses_rls").all?(true) &&
      status["execute_grantees"].sort == expected && status["grant_option_granted"] == false &&
      status["runtime_can_execute"] != false
  end

  # The guard and tenant scope treat only a known bypass as a bypass, so an
  # unreadable switch keeps them enforcing.
  def self.bypass_enabled?(connection)
    bypass_state(connection) == true
  end

  # true, false, or nil when the singleton row is missing (unknown). Callers
  # that open something on "no bypass" must compare with false, so unknown
  # fails closed. Tests can exercise the switch explicitly; production
  # consults the durable switch only after the direct runtime URL has been
  # configured.
  def self.bypass_state(connection)
    return false unless RlsConfiguration.runtime_url

    cached = SWITCH_CACHE.get
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return cached.first if cached && now < cached.last

    value = connection.select_value("SELECT bypass_enabled FROM #{SWITCH} WHERE singleton")
    state = [ true, false ].include?(value) ? value : nil
    SWITCH_CACHE.compare_and_set(cached, [ state, now + 5 ].freeze)
    state
  end
end
