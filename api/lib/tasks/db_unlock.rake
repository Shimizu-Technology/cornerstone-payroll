namespace :db do
  desc "Release stale advisory locks before running migrations (fixes Neon/PgBouncer orphaned locks)"
  task clear_advisory_locks: :environment do
    conn = ActiveRecord::Base.connection

    # 1) Terminate any *advisory-lock-holding* backend other than us. This
    #    is the lock that crashes the next deploy with "Cannot run
    #    migrations because another migration process is currently
    #    running" when Render's prior build was killed mid-migration on
    #    Neon. The previous version of this task only terminated
    #    backends with `state != 'active'`, which misses the orphaned
    #    lock-holder (its state is usually `'idle'` because the build
    #    process exited but Neon's pooler is still holding the
    #    socket open).
    advisory_holders = conn.execute(<<~SQL).to_a
      SELECT pl.pid
        FROM pg_locks pl
        JOIN pg_stat_activity psa ON psa.pid = pl.pid
       WHERE pl.locktype = 'advisory'
         AND pl.pid != pg_backend_pid()
         AND psa.datname = current_database()
    SQL

    if advisory_holders.any?
      Rails.logger.info "[db:clear_advisory_locks] Terminating #{advisory_holders.size} backend(s) holding advisory locks..."
      advisory_holders.each do |row|
        conn.execute("SELECT pg_terminate_backend(#{row['pid']})")
      end
      Rails.logger.info "[db:clear_advisory_locks] Done (advisory holders)."
    end

    # 2) Clean up any other stale (non-active, non-self) connections.
    #    Belt-and-suspenders for connection-pool churn from earlier
    #    failed deploys.
    stale = conn.execute(<<~SQL).to_a
      SELECT pid
        FROM pg_stat_activity
       WHERE datname = current_database()
         AND pid != pg_backend_pid()
         AND state != 'active'
    SQL

    if stale.any?
      Rails.logger.info "[db:clear_advisory_locks] Terminating #{stale.size} stale connection(s)..."
      stale.each do |row|
        conn.execute("SELECT pg_terminate_backend(#{row['pid']})")
      end
      Rails.logger.info "[db:clear_advisory_locks] Done (stale connections)."
    end

    if advisory_holders.empty? && stale.empty?
      Rails.logger.info "[db:clear_advisory_locks] No stale connections or advisory locks found."
    end
  end

  desc "Safe migration: clear stale locks, run db:prepare, retry on Neon's mid-migration connection recycling"
  task safe_prepare: :environment do
    max_attempts = (ENV["SAFE_PREPARE_MAX_ATTEMPTS"] || "4").to_i
    attempt      = 0

    begin
      attempt += 1

      # Re-enable the prereq + downstream tasks so each retry actually
      # re-runs them. Rake marks tasks as "invoked" after their first
      # run and silently no-ops subsequent invocations otherwise.
      %w[db:clear_advisory_locks db:prepare db:migrate db:schema:load].each do |t|
        Rake::Task[t].reenable if Rake::Task.task_defined?(t)
      end

      Rake::Task["db:clear_advisory_locks"].invoke
      Rake::Task["db:prepare"].invoke

      if attempt > 1
        warn "[db:safe_prepare] Migrations completed on attempt #{attempt}/#{max_attempts}."
      end
    rescue ActiveRecord::ConcurrentMigrationError => e
      decision = handle_concurrent_migration_error!(e, attempt: attempt, max_attempts: max_attempts)
      case decision
      when :retry     then retry
      when :recovered then :ok # fall through to success
      else                 raise
      end
    end
  end

  # ----------------------------------------------------------------------
  # Recovery + retry handler for Neon's serverless connection recycling.
  #
  # Symptoms (from real Render deploy logs against this codebase):
  #
  #   WARNING:  you don't own a lock of type ExclusiveLock
  #   ActiveRecord::ConcurrentMigrationError: Failed to release advisory lock
  #
  #   ActiveRecord::ConcurrentMigrationError: Cannot run migrations
  #   because another migration process is currently running.
  #
  # Both shapes have the same root cause: Neon's pooler recycles idle
  # Postgres connections aggressively, and Rails 8 takes the migration
  # advisory lock *per migration* (not per batch). A long migration
  # (e.g. ScopePrinterProfilesToUser, 8 SQL statements + dedupe + index
  # rebuild) can outlive its underlying connection. Each individual
  # statement still commits (separate transactions), but Rails'
  # `pg_advisory_unlock` cleanup at the end of the migration fires
  # `false` because the new connection doesn't own the lock the
  # original one took. ConcurrentMigrationError fires; subsequent
  # pending migrations in the same batch never run.
  #
  # Strategy:
  #   * If `migrations_pending?` is false → schema is already in the
  #     intended end state. The error was the orphaned-lock-after-
  #     success scenario; log loudly and continue (`:recovered`).
  #   * If `migrations_pending?` is true → some migrations applied
  #     but more are needed. Postgres auto-releases the orphaned
  #     session-scoped lock when the dead session is reaped, so the
  #     next attempt starts clean. Retry up to `max_attempts`
  #     (`:retry`).
  #   * If we've exhausted retries → `:reraise`.
  # ----------------------------------------------------------------------
  def handle_concurrent_migration_error!(error, attempt:, max_attempts:)
    ActiveRecord::Base.connection_pool.disconnect!

    if migrations_pending?
      if attempt >= max_attempts
        warn "[db:safe_prepare] Still pending after #{attempt}/#{max_attempts} attempts — giving up."
        warn "[db:safe_prepare]   Last error: #{error.message}"
        :reraise
      else
        warn "[db:safe_prepare] Attempt #{attempt}/#{max_attempts} hit ConcurrentMigrationError with " \
             "pending migrations remaining. Retrying with fresh connections after a brief backoff..."
        warn "[db:safe_prepare]   Error: #{error.message}"
        sleep_for_backoff(attempt)
        :retry
      end
    else
      warn "[db:safe_prepare] Recovered from ConcurrentMigrationError after a successful migration run " \
           "(Neon connection recycling). All migrations are applied; continuing the deploy."
      warn "[db:safe_prepare]   Original error: #{error.message}"
      :recovered
    end
  end

  # Cross-Rails-version migration-status check. Rails 8 moved
  # `migration_context` off the connection adapter onto the connection
  # pool, so the obvious `connection.migration_context.needs_migration?`
  # crashes with NoMethodError on Rails 8. We just compare on-disk
  # migration files to the `schema_migrations` table directly — that
  # API is stable across every Rails version we've ever shipped on.
  def migrations_pending?
    paths        = ActiveRecord::Migrator.migrations_paths
    on_disk      = ActiveRecord::MigrationContext.new(paths).migrations.map(&:version).map(&:to_i)
    applied_rows = ActiveRecord::Base.connection.execute("SELECT version FROM schema_migrations")
    applied_set  = applied_rows.map { |row| row["version"].to_i }.to_set

    pending = on_disk.reject { |v| applied_set.include?(v) }
    if pending.any?
      Rails.logger.warn "[db:safe_prepare] Pending migrations after recovery check: #{pending.inspect}"
    end
    pending.any?
  end

  # Capped exponential-ish backoff so the retry isn't instant (gives
  # Postgres a moment to reap the recycled session and release the
  # orphaned lock if it hasn't already).
  def sleep_for_backoff(attempt)
    secs = [2 * attempt, 10].min
    Rails.logger.info "[db:safe_prepare] Sleeping #{secs}s before retry..."
    sleep(secs)
  end
end
