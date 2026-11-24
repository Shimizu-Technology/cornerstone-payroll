# frozen_string_literal: true

namespace :rls do
  desc "Stage policies and the kill switch through the direct migration connection"
  task install: :environment do
    abort "Boot with RLS_CONTEXT_GUARD_MODE=off for owner maintenance" if RlsContextGuard.enabled?
    url = RlsConfiguration.direct_url!(ENV.fetch("MIGRATION_DATABASE_URL"), "MIGRATION_DATABASE_URL")
    record = RlsMaintenanceRecord
    record.establish_connection(url)
    record.connection_pool.with_connection { |connection| RlsDatabase.install!(connection) }
  ensure
    record&.remove_connection
  end

  desc "Report the runtime role, guard mode and table policies without writing"
  task status: :environment do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      installed = connection.select_value("SELECT to_regclass('rls_admin.rls_kill_switch') IS NOT NULL")
      puts JSON.pretty_generate(
        guard_mode: RlsContextGuard.mode,
        direct_runtime_configured: RlsConfiguration.runtime_url.present?,
        role: connection.select_one("SELECT rolname, rolbypassrls, rolsuper FROM pg_roles WHERE rolname = current_user"),
        kill_switch: installed && connection.select_value("SELECT bypass_enabled FROM rls_admin.rls_kill_switch WHERE singleton"),
        tables: RlsDatabase.table_status(connection),
        login_link_decision: RlsDatabase.login_link_decision_status(connection)
      )
    end
  end

  desc "Summarize structured RLS warnings from an exported JSON-lines log on standard input"
  task :shadow_report do
    require "json"
    counts = Hash.new(0)
    $stdin.each_line do |line|
      # Rails or the log shipper may prepend a severity and timestamp.
      start = line.index("{")
      next unless start

      event = JSON.parse(line[start..])
      next unless %w[rls_missing_context rls_unclassified_sql].include?(event["event"])

      counts[[ event["event"], event["call_site"], event["tables"] ]] += 1
    rescue JSON::ParserError
      next
    end
    puts JSON.pretty_generate(counts.map do |(event, site, tables), count|
      { event: event, call_site: site, tables: tables, count: count }
    end)
  end

  desc "Disable enforced company policies using the direct owner connection"
  task :disable do
    require "pg"
    require_relative "../rls_configuration"
    require_relative "../rls_tables"

    url = RlsConfiguration.direct_url!(ENV.fetch("MIGRATION_DATABASE_URL"), "MIGRATION_DATABASE_URL")
    PG.connect(url) do |connection|
      connection.exec("SET lock_timeout = '3s'")
      enforced = connection.exec(<<~SQL).column_values(0)
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND (c.relrowsecurity OR c.relforcerowsecurity)
      SQL
      pending = enforced & RlsTables::PROTECTED_TABLES.to_a
      failed = pending.reject do |table|
        identifier = connection.quote_ident(table)
        disabled = false
        3.times do |attempt|
          connection.transaction do
            connection.exec("ALTER TABLE public.#{identifier} NO FORCE ROW LEVEL SECURITY")
            connection.exec("ALTER TABLE public.#{identifier} DISABLE ROW LEVEL SECURITY")
          end
          disabled = true
          puts "Disabled RLS on #{table}"
          break
        rescue PG::LockNotAvailable
          sleep(attempt + 1) if attempt < 2
        end
        disabled
      end
      abort "Failed to lock: #{failed.join(', ')}" if failed.any?
    end
  end
end
