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
        enforcement: RlsDatabase.enforcement_summary(connection),
        tables: RlsDatabase.table_status(connection),
        login_link_decision: RlsDatabase.login_link_decision_status(connection)
      )
    end
  end

  desc "Enable and force company policies in batches using the direct owner connection " \
       "(TABLES=a,b for a subset, DRY_RUN=1 to list, BATCH_SIZE=, BATCH_PAUSE= seconds)"
  task enforce: :environment do
    require Rails.root.join("lib/rls_enforcement")

    abort "Boot with RLS_CONTEXT_GUARD_MODE=off for owner maintenance" if RlsContextGuard.enabled?
    tables = begin
      RlsEnforcement.select_tables(ENV.key?("TABLES") ? ENV["TABLES"] : nil)
    rescue ArgumentError => error
      abort error.message
    end
    dry_run = case ENV["DRY_RUN"]
    when nil, "0" then false
    when "1" then true
    else abort "DRY_RUN must be 1 (list only) or 0"
    end
    url = RlsConfiguration.direct_url!(ENV.fetch("MIGRATION_DATABASE_URL"), "MIGRATION_DATABASE_URL")
    record = RlsMaintenanceRecord
    record.establish_connection(url)
    record.connection_pool.with_connection do |connection|
      abort "Another rls:enforce or rls:disable holds the enforcement lock" unless dry_run || RlsEnforcement.lock!(connection)
      failures = RlsEnforcement.preflight_failures(connection)
      abort "Refusing to enforce RLS:\n- #{failures.join("\n- ")}" if failures.any?

      pending = RlsEnforcement.pending(connection, tables)
      batch_size = Integer(ENV.fetch("BATCH_SIZE", RlsEnforcement::BATCH_SIZE))
      if dry_run
        puts "Dry run: #{pending.size} of #{tables.size} selected tables need ENABLE and FORCE"
        pending.each_slice(batch_size).with_index(1) { |batch, index| puts "Batch #{index}: #{batch.join(', ')}" }
        next
      end

      failed, stopped = begin
        [ RlsEnforcement.enforce!(connection, pending, batch_size: batch_size, pause: Float(ENV.fetch("BATCH_PAUSE", "5"))), nil ]
      rescue RlsEnforcement::Stopped => error
        [ [], error.message ]
      end
      result = RlsEnforcement.verification(connection, tables)
      puts JSON.pretty_generate(result)
      abort stopped if stopped
      abort "Failed to lock: #{failed.join(', ')}. Rerun to resume." if failed.any?
      abort "Not enforced: #{result['selected_not_enforced'].join(', ')}" if result["selected_not_enforced"].any?
      abort "The kill switch changed during the run" unless result["kill_switch_bypass"] == false
      puts(result["all_enforced"] ? "All protected tables are enabled and forced" : "Selected tables are enabled and forced")
    end
  ensure
    record&.remove_connection
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
      # Waits a bounded time for a running rls:enforce, which stops before
      # its next table once the kill switch is set.
      wait = Integer(ENV.fetch("LOCK_WAIT", "60"))
      begin
        connection.exec("SET lock_timeout = '#{wait}s'")
        connection.exec("SELECT pg_advisory_lock(#{RlsConfiguration::OWNER_TASK_LOCK})")
      rescue PG::LockNotAvailable
        abort "An rls:enforce still holds the enforcement lock after #{wait}s. Set the kill switch first; " \
              "enforce stops before its next table. Then rerun rls:disable (LOCK_WAIT= seconds to wait longer)."
      end
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
