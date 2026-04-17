namespace :db do
  # The fixed numeric advisory-lock id Rails uses for the migration
  # mutex (see ActiveRecord::Migration#generate_migrator_advisory_lock_id).
  # Rails computes a per-database 64-bit id; we don't need to recreate it
  # because the `pg_locks` query below filters by `locktype = 'advisory'`
  # which already narrows to migration-style locks.

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

  desc "Safe migration: clear stale locks, run db:prepare, recover from Neon's mid-migration connection recycling"
  task safe_prepare: :clear_advisory_locks do
    # Invoke db:prepare INSIDE the rescue (not as a Rake prereq) so we
    # can catch ConcurrentMigrationError and decide whether to recover
    # or re-raise.
    begin
      Rake::Task["db:prepare"].invoke
    rescue ActiveRecord::ConcurrentMigrationError => e
      handle_orphaned_advisory_lock_error!(e)
    end
  end

  # ----------------------------------------------------------------------
  # Recovery helper for Neon's serverless connection recycling.
  #
  # Symptom (from real Render deploy logs):
  #
  #   WARNING:  you don't own a lock of type ExclusiveLock
  #   ActiveRecord::ConcurrentMigrationError: Failed to release advisory lock
  #
  # Root cause: Neon aggressively recycles idle Postgres connections.
  # When a long migration's underlying connection gets recycled while
  # the migration is running, the migration body's individual SQL
  # statements still commit (each in its own transaction), but Rails'
  # final `pg_advisory_unlock` cleanup fires `false` because the new
  # connection doesn't own the lock the original one took. Rails
  # raises ConcurrentMigrationError and crashes the deploy — even
  # though the schema has actually advanced.
  #
  # We distinguish that *phantom* failure from a real concurrency
  # conflict by re-checking migration status against the database. If
  # everything on disk is in `schema_migrations`, proceed (logging
  # loudly). Otherwise, re-raise so the deploy fails fast.
  # ----------------------------------------------------------------------
  def handle_orphaned_advisory_lock_error!(error)
    # Force a fresh connection so the status check below reads the
    # *real* schema_migrations state, not anything cached on the
    # doomed connection that just raised.
    ActiveRecord::Base.connection_pool.disconnect!

    if migrations_pending?
      warn "[db:safe_prepare] db:prepare raised ConcurrentMigrationError AND migrations are still pending — re-raising."
      raise error
    end

    warn "[db:safe_prepare] Recovered from ConcurrentMigrationError after a successful migration run " \
         "(Neon connection recycling). All migrations are applied; continuing the deploy."
    warn "[db:safe_prepare]   Original error: #{error.message}"
  end

  # Cross-Rails-version migration-status check. Rails 8 moved
  # `migration_context` off the connection adapter onto the connection
  # pool, so the obvious `connection.migration_context.needs_migration?`
  # crashes with NoMethodError on Rails 8 (which is what hit us on the
  # last deploy). Rather than version-detect, we just compare on-disk
  # migration files to the `schema_migrations` table directly — that
  # API is stable across every Rails version we've ever shipped on.
  def migrations_pending?
    paths           = ActiveRecord::Migrator.migrations_paths
    on_disk         = ActiveRecord::MigrationContext.new(paths).migrations.map(&:version).map(&:to_i)
    applied_rows    = ActiveRecord::Base.connection.execute("SELECT version FROM schema_migrations")
    applied_set     = applied_rows.map { |row| row["version"].to_i }.to_set

    pending = on_disk.reject { |v| applied_set.include?(v) }
    if pending.any?
      Rails.logger.warn "[db:safe_prepare] Pending migrations after recovery check: #{pending.inspect}"
    end
    pending.any?
  end
end
