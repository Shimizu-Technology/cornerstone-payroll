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

  desc "Safe migration: clear stale locks, then run db:prepare"
  task safe_prepare: [:clear_advisory_locks, :prepare]
end
