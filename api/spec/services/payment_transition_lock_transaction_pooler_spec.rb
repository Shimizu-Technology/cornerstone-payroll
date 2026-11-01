# frozen_string_literal: true

require "rails_helper"

# Staging and production reach Neon through its PgBouncer pooler in
# transaction mode. Consecutive autocommit statements from one Rails
# connection may run on different PostgreSQL server backends there, and a
# backend keeps serving other clients after a session lock is stranded on it.
#
# Run against a local transaction-mode PgBouncer:
#   TEST_DATABASE_URL=postgres://127.0.0.1:6439/<db> \
#   TRANSACTION_POOLER_URL=postgres://127.0.0.1:6439/<db> \
#   TRANSACTION_POOLER_DIRECT_URL=postgres://127.0.0.1:5432/<db> \
#   bundle exec rspec spec/services/payment_transition_lock_transaction_pooler_spec.rb
RSpec.describe TimeTracking::PaymentCancellationBridge, :transaction_pooler do
  self.use_transactional_tests = false

  before do
    skip "Set TRANSACTION_POOLER_URL and TRANSACTION_POOLER_DIRECT_URL to run against a transaction pooler" unless
      ENV["TRANSACTION_POOLER_URL"].present? && ENV["TRANSACTION_POOLER_DIRECT_URL"].present?
  end

  let(:item_id) { SecureRandom.random_number(1_000_000_000) + 1 }
  let(:key) { 4_100_000_000_000_000_000 + item_id }

  def advisory_locks_held
    direct = PG.connect(ENV.fetch("TRANSACTION_POOLER_DIRECT_URL"))
    direct.exec("SELECT pid, classid, objid FROM pg_locks WHERE locktype = 'advisory' AND granted").to_a
  ensure
    direct&.close
  end

  # Another pooled client (for example a Solid Queue worker thread at a minute
  # boundary) opens a transaction on the exact server backend that ran the
  # lock statement and is still in it when the bridge releases, so the release
  # statement is routed to another backend. A backend pinned by an open
  # transaction is not available to other clients, so there is nothing to take.
  def occupy_lock_backend!(others)
    holder = advisory_locks_held.map { |row| row.fetch("pid").to_i }.first
    return unless holder && backend_state(holder) == "idle"

    3.times do
      other = PG.connect(ENV.fetch("TRANSACTION_POOLER_URL"))
      other.exec("BEGIN")
      others << other
      return if other.exec("SELECT pg_backend_pid()").getvalue(0, 0).to_i == holder
    end
  end

  def backend_state(pid)
    direct = PG.connect(ENV.fetch("TRANSACTION_POOLER_DIRECT_URL"))
    direct.exec_params("SELECT state FROM pg_stat_activity WHERE pid = $1", [ pid ]).getvalue(0, 0)
  ensure
    direct&.close
  end

  def finish(others)
    others.each { |other| other.exec("COMMIT") && other.close }
  end

  def stranded_lock_attempt(others, &)
    described_class.with_item_lock(item_id) do
      occupy_lock_backend!(others)
      yield if block_given?
    end
  ensure
    finish(others)
    others.clear
  end

  it "releases the item lock when another client takes the backend between lock and unlock" do
    stranded_lock_attempt([])

    expect(advisory_locks_held).to eq([])
  end

  it "releases the item lock after an exception while another client holds the lock backend" do
    expect { stranded_lock_attempt([]) { raise "Synthetic remote failure" } }.to raise_error(RuntimeError, "Synthetic remote failure")

    expect(advisory_locks_held).to eq([])
  end

  it "does not leave the next transition for the item blocked behind the pooler" do
    stub_const("#{described_class}::LOCK_WAIT_SECONDS", 1)
    stranded_lock_attempt([])

    expect(described_class.with_item_lock(item_id) { :next_transition }).to eq(:next_transition)
    expect(advisory_locks_held).to eq([])
  end

  it "excludes another pooled client for the whole hold" do
    stub_const("#{described_class}::LOCK_WAIT_SECONDS", 0.3)
    outcome = described_class.with_item_lock(item_id) do
      Thread.new do
        described_class.with_item_lock(item_id) { :entered }
      rescue TimeTracking::Client::Error => e
        e.message
      end.value
    end

    expect(outcome).to eq("Another payment transition is in progress; refresh and retry")
    expect(advisory_locks_held).to eq([])
  end
end
