# frozen_string_literal: true

# Holds a PostgreSQL advisory lock across several short application
# transactions and remote I/O without depending on which server backend runs
# each application statement.
#
# Hosted Payroll reaches Neon through PgBouncer in transaction mode. A session
# lock taken by one autocommit statement and released by a later one can run
# on two different server backends there: the release returns false and the
# lock stays on a backend that keeps serving other clients until the pooler
# closes it. Another client routed to that backend would also be granted the
# "held" lock re-entrantly.
#
# This lock instead lives in one open transaction on a dedicated connection
# outside the Active Record pool. A pooler pins a server backend for the length
# of a transaction, and ending that transaction always releases the lock on
# the backend that took it: normal exit, an exception, a non-local return, an
# aborted caller transaction, a lost connection, process exit, or PostgreSQL's
# idle-in-transaction timeout after MAX_HOLD all end it. Re-entry for the same
# key in the same thread or fiber reuses the outer lock.
class DedicatedAdvisoryLock
  class Unavailable < StandardError; end

  MAX_HOLD = "20min"
  POLL_SECONDS = 0.05
  APPLICATION_NAME = "payroll advisory lock"

  def self.with_lock(key, wait_seconds:)
    key = Integer(key)
    held = (ActiveSupport::IsolatedExecutionState[:dedicated_advisory_locks] ||= Set.new)
    return yield if held.include?(key)

    lock = new(key)
    lock.acquire!(wait_seconds)
    held << key
    begin
      yield
    ensure
      held.delete(key)
      lock.release
    end
  end

  def initialize(key)
    @key = key
  end

  def acquire!(wait_seconds)
    acquired = false
    @adapter = open_adapter
    @pg = @adapter.raw_connection
    @pg.exec("BEGIN")
    # The hosted database sets this to five minutes. Bound the hold explicitly so a hung
    # holder cannot strand the key, without ending a normal transition early.
    @pg.exec("SET LOCAL idle_in_transaction_session_timeout = '#{MAX_HOLD}'")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
    until locked?
      raise Unavailable, "advisory lock #{@key} is held" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep POLL_SECONDS
    end
    acquired = true
    self
  ensure
    # Includes interrupts such as Thread#kill while waiting.
    close unless acquired
  end

  def release
    @pg.exec("COMMIT")
  rescue PG::Error => e
    # The transaction already ended (connection lost or hold timeout), which
    # released the lock server-side. Record that the hold was not continuous.
    Rails.logger.error("[DedicatedAdvisoryLock] lock #{@key} ended before release: #{e.class}: #{e.message}")
  ensure
    close
  end

  private

  def locked?
    # Rails installs result decoders on its raw connections; accept either form.
    @pg.exec_params("SELECT pg_try_advisory_xact_lock($1::bigint)", [ @key ]).getvalue(0, 0).in?([ true, "t" ])
  end

  def open_adapter
    db_config = ApplicationRecord.connection_db_config
    db_config.adapter_class.new(db_config.configuration_hash.merge(application_name: APPLICATION_NAME))
  end

  def close
    # Closing the socket ends the session, and with it any lock still held.
    @pg.close if @pg && !@pg.finished?
    @adapter&.disconnect!
  rescue StandardError => e
    Rails.logger.error("[DedicatedAdvisoryLock] closing lock #{@key} connection failed: #{e.class}: #{e.message}")
  ensure
    @adapter = @pg = nil
  end
end
