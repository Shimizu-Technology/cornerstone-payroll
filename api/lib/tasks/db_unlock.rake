namespace :db do
  desc "Release stale advisory locks before running migrations (fixes Neon/PgBouncer orphaned locks)"
  task clear_advisory_locks: :environment do
    conn = ActiveRecord::Base.connection

    stale = conn.execute(<<~SQL).to_a
      SELECT pid, state, query_start, backend_start
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
      Rails.logger.info "[db:clear_advisory_locks] Done."
    else
      Rails.logger.info "[db:clear_advisory_locks] No stale connections found."
    end
  end

  desc "Safe migration: clear stale locks, run db:prepare, recover from Neon's mid-migration connection recycling"
  task safe_prepare: :clear_advisory_locks do
    # We deliberately do NOT declare `db:prepare` as a prerequisite of
    # `safe_prepare` (the previous version did). Prereqs run via
    # Rake's invocation graph and bypass our rescue block — wrapping
    # the call lets us catch the specific failure mode below.
    begin
      Rake::Task["db:prepare"].invoke
    rescue ActiveRecord::ConcurrentMigrationError => e
      handle_orphaned_advisory_lock_error!(e)
    end
  end

  # ----------------------------------------------------------------------
  # Recovery helper for Neon's serverless connection recycling.
  #
  # Symptom (verbatim from a real Render deploy):
  #
  #   WARNING:  you don't own a lock of type ExclusiveLock
  #   ActiveRecord::ConcurrentMigrationError: Failed to release advisory lock
  #
  # Root cause: Neon aggressively recycles idle Postgres connections.
  # When a long migration's underlying connection gets recycled while
  # the migration is running, the migration body's individual SQL
  # statements still commit (each in its own transaction), but Rails'
  # final `pg_advisory_unlock` cleanup fires `false` because the new
  # connection doesn't own the lock the original one took. Rails wraps
  # that into `ConcurrentMigrationError` and crashes the deploy — even
  # though the schema has actually advanced.
  #
  # This handler distinguishes that *phantom* failure from a real
  # concurrency conflict by re-checking migration status against the
  # database. If all migrations on disk are present in
  # `schema_migrations`, the schema is in the intended end state and
  # we proceed (logging loudly so it's still visible in deploy logs).
  # If any migration is pending, the error was real — re-raise so the
  # deploy fails fast.
  # ----------------------------------------------------------------------
  def handle_orphaned_advisory_lock_error!(error)
    # Force a fresh connection so `needs_migration?` reads the *real*
    # schema_migrations state, not anything cached on the doomed
    # connection that just raised.
    ActiveRecord::Base.connection_pool.disconnect!

    pending = ActiveRecord::Base.connection.migration_context.needs_migration?

    if pending
      warn "[db:safe_prepare] db:prepare raised ConcurrentMigrationError AND migrations are still pending — re-raising."
      raise error
    end

    warn "[db:safe_prepare] Recovered from orphaned-advisory-lock error after a successful migration run " \
         "(Neon connection recycling). All migrations are applied; continuing the deploy."
    warn "[db:safe_prepare]   Original error: #{error.message}"
  end
end
