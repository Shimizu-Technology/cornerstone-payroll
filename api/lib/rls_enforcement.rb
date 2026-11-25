# frozen_string_literal: true

require_relative "rls_database"
require_relative "../db/migrate/support/m3_7_child_companies"

# M3-7 step 3: ENABLE and FORCE row-level security table by table over the
# direct migration-owner connection. Each table commits on its own with a
# short lock timeout, so a busy table delays only itself. Rollback is
# rls:disable, after the kill switch.
module RlsEnforcement
  LOCK_TIMEOUT = "3s"
  ATTEMPTS = 3
  BATCH_SIZE = 10
  class Stopped < StandardError; end

  # The busiest payroll tables go last, so a lock or policy problem shows up
  # first on low-traffic tables and the window can stop before payroll runs
  # are affected.
  CORE_TABLES = %w[
    timecards punch_entries daily_time_records employee_wage_rates employee_deductions
    payroll_item_earnings payroll_item_deductions payroll_items pay_periods
    departments employees audit_logs
  ].freeze

  def self.ordered_tables
    rest = RlsTables::PROTECTED_TABLES.to_a - CORE_TABLES
    rest.sort + CORE_TABLES
  end

  # nil (TABLES absent) selects every protected table. A blank list and
  # unknown names are errors, never silently widened or skipped.
  def self.select_tables(names)
    return ordered_tables if names.nil?

    requested = names.split(/[\s,]+/).reject(&:empty?).uniq
    raise ArgumentError, "TABLES is empty; omit it to select every protected table" if requested.empty?
    unknown = requested - RlsTables::PROTECTED_TABLES.to_a
    raise ArgumentError, "Not RLS-protected tables: #{unknown.join(', ')}" if unknown.any?

    ordered_tables & requested
  end

  # Reasons the database is not ready to enforce. Empty means ready.
  def self.preflight_failures(connection)
    failures = []
    switch = RlsDatabase.kill_switch(connection)
    failures << "the kill switch is #{switch.nil? ? 'missing or unreadable' : 'bypassing'}" unless switch == false

    status = RlsDatabase.table_status(connection)
    missing = RlsTables::PROTECTED_TABLES.to_a - status.map { |row| row.fetch("table") }
    unstaged = status.reject { |row| row.fetch("policy") }.map { |row| row.fetch("table") }
    failures << "policies are not staged on: #{(missing + unstaged).sort.join(', ')}" if (missing + unstaged).any?

    failures << "the login link decision function is not restricted (see rls:status)" unless RlsDatabase.login_link_decision_ready?(connection)
    failures << "payroll_app must exist without BYPASSRLS and with SELECT-only kill switch access" unless runtime_role_ready?(connection)
    unless connection.select_value("SELECT rolbypassrls OR rolsuper FROM pg_roles WHERE rolname = current_user") == true
      failures << "the migration owner must bypass RLS, or forced policies would block migrations"
    end

    nullable = nullable_child_companies(connection)
    failures << "company_id is still nullable on #{nullable.join(', ')}; deploy the contract migration first" if nullable.any?
    failures
  end

  def self.runtime_role_ready?(connection)
    connection.select_value(<<~SQL) == true
      SELECT NOT rolbypassrls AND NOT rolsuper
        AND has_table_privilege(oid, '#{RlsDatabase::SWITCH}', 'SELECT')
        AND NOT has_table_privilege(oid, '#{RlsDatabase::SWITCH}', 'INSERT,UPDATE,DELETE,TRUNCATE')
      FROM pg_roles WHERE rolname = 'payroll_app'
    SQL
  end

  def self.nullable_child_companies(connection)
    names = M3_7ChildCompanies::CHILDREN.keys.map { |table| connection.quote(table.to_s) }.join(", ")
    connection.select_values(<<~SQL).sort
      SELECT table_name FROM information_schema.columns
      WHERE table_schema = current_schema() AND column_name = 'company_id' AND is_nullable = 'YES'
        AND table_name IN (#{names})
    SQL
  end

  # true when this session now holds the lock shared with rls:disable. It
  # is released when the maintenance connection closes.
  def self.lock!(connection)
    connection.select_value("SELECT pg_try_advisory_lock(#{RlsConfiguration::OWNER_TASK_LOCK})") == true
  end

  def self.enforced?(row)
    row.fetch("policy") && row.fetch("enabled") && row.fetch("forced")
  end

  # The selected tables that still need ENABLE or FORCE, in run order.
  def self.pending(connection, tables)
    done = RlsDatabase.table_status(connection).select { |row| enforced?(row) }.map { |row| row.fetch("table") }
    tables - done
  end

  # Returns the tables that could not be locked after every attempt. Stops
  # before the next table once the kill switch is no longer off, so an
  # incident rollback is never undone by a run still in progress.
  def self.enforce!(connection, tables, batch_size: BATCH_SIZE, pause: 0, out: $stdout, sleeper: method(:sleep))
    batches = tables.each_slice(batch_size).to_a
    failed = []
    batches.each_with_index do |batch, index|
      out.puts "Batch #{index + 1}/#{batches.size}: #{batch.join(', ')}"
      batch.each do |table|
        raise Stopped, "The kill switch is no longer off; stopped before #{table}" unless RlsDatabase.kill_switch(connection) == false

        enforce_table!(connection, table, out: out, sleeper: sleeper) || failed << table
      end
      sleeper.call(pause) if pause.positive? && index < batches.size - 1
    end
    failed
  end

  def self.enforce_table!(connection, table, out:, sleeper:)
    identifier = connection.quote_table_name(table)
    ATTEMPTS.times do |attempt|
      connection.transaction do
        connection.execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
        connection.execute("ALTER TABLE #{identifier} ENABLE ROW LEVEL SECURITY")
        connection.execute("ALTER TABLE #{identifier} FORCE ROW LEVEL SECURITY")
      end
      out.puts "Enforced RLS on #{table}"
      return true
    rescue ActiveRecord::LockWaitTimeout
      out.puts "Lock timeout on #{table} (attempt #{attempt + 1}/#{ATTEMPTS})"
      sleeper.call(attempt + 1) if attempt < ATTEMPTS - 1
    end
    false
  end

  # Every protected table, with the selected ones that are not enforced.
  def self.verification(connection, tables)
    rows = RlsDatabase.table_status(connection)
    enforced = rows.select { |row| enforced?(row) }.map { |row| row.fetch("table") }
    {
      "protected_tables" => RlsTables::PROTECTED_TABLES.size,
      "enforced_tables" => enforced.size,
      "selected_not_enforced" => tables - enforced,
      "all_enforced" => enforced.size == RlsTables::PROTECTED_TABLES.size,
      "kill_switch_bypass" => RlsDatabase.kill_switch(connection)
    }
  end
end
