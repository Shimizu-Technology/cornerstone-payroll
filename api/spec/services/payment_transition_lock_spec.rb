# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::PaymentCancellationBridge do
  self.use_transactional_tests = false

  let(:item_id) { SecureRandom.random_number(1_000_000_000) + 1 }
  let(:key) { described_class::LOCK_KEY_BASE + item_id }

  # A separate direct session. When this file runs through a transaction
  # pooler, TRANSACTION_POOLER_DIRECT_URL bypasses it for observation.
  def observer
    @observer ||= if ENV["TRANSACTION_POOLER_DIRECT_URL"].present?
      PG.connect(ENV["TRANSACTION_POOLER_DIRECT_URL"])
    else
      ApplicationRecord.connection_db_config.adapter_class
        .new(ApplicationRecord.connection_db_config.configuration_hash).raw_connection
    end
  end

  def item_lock_holders
    observer.exec_params(<<~SQL, [ key >> 32, key & 0xffffffff ]).values
      SELECT pid FROM pg_locks
      WHERE locktype = 'advisory' AND objsubid = 1 AND classid = $1::bigint::oid AND objid = $2::bigint::oid
    SQL
  end

  def other_session_can_lock?
    locked = ActiveModel::Type::Boolean.new.cast(observer.exec_params("SELECT pg_try_advisory_lock($1::bigint)", [ key ]).getvalue(0, 0))
    observer.exec_params("SELECT pg_advisory_unlock($1::bigint)", [ key ]) if locked
    locked
  end

  after { @observer&.close }

  it "serializes concurrent native and source transitions and releases the lock on an exception" do
    acquired = Queue.new
    release = Queue.new
    second_entered = Queue.new
    first = Thread.new do
      described_class.with_item_lock(item_id) do
        acquired << true
        release.pop
        raise "Synthetic lost acknowledgement"
      end
    rescue RuntimeError => e
      e.message
    end
    acquired.pop
    second = Thread.new { described_class.with_item_lock(item_id) { second_entered << true } }
    sleep 0.1
    expect(second_entered.empty?).to be(true)
    expect(item_lock_holders.size).to eq(1)
    release << true
    expect(first.value).to eq("Synthetic lost acknowledgement")
    second.join(3)
    expect(second.alive?).to be(false)
    expect(second_entered.pop).to be(true)
    expect(item_lock_holders).to eq([])
    expect(other_session_can_lock?).to be(true)
  ensure
    release << true if first&.alive?
    first&.join(3)
    second&.join(3)
  end

  it "holds the lock across separate committed transactions and releases it after success" do
    observed = described_class.with_item_lock(item_id) do
      2.times { ApplicationRecord.transaction { ApplicationRecord.connection.select_value("SELECT 1") } }
      [ item_lock_holders.size, other_session_can_lock? ]
    end

    expect(observed).to eq([ 1, false ])
    expect(item_lock_holders).to eq([])
    expect(other_session_can_lock?).to be(true)
  end

  it "releases the lock after an aborted transaction inside the block" do
    expect do
      described_class.with_item_lock(item_id) do
        ApplicationRecord.transaction { ApplicationRecord.connection.execute("SELECT 1 / 0") }
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /division by zero/)

    expect(item_lock_holders).to eq([])
    expect(other_session_can_lock?).to be(true)
  end

  it "releases the lock when the caller's surrounding transaction is aborted" do
    expect do
      ApplicationRecord.transaction do
        described_class.with_item_lock(item_id) { ApplicationRecord.connection.execute("SELECT 1 / 0") }
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /division by zero/)

    expect(item_lock_holders).to eq([])
    expect(other_session_can_lock?).to be(true)
  end

  it "releases the lock on a non-local return from the block" do
    early_return = Class.new do
      def call(item_id)
        TimeTracking::PaymentCancellationBridge.with_item_lock(item_id) { return :returned }
        :not_returned
      end
    end

    expect(early_return.new.call(item_id)).to eq(:returned)
    expect(item_lock_holders).to eq([])
  end

  it "keeps the outer lock through a nested acquisition and releases it once on the outer exit" do
    described_class.with_item_lock(item_id) do
      described_class.with_item_lock(item_id) { expect(item_lock_holders.size).to eq(1) }
      expect(item_lock_holders.size).to eq(1)
      expect(other_session_can_lock?).to be(false)
    end

    expect(item_lock_holders).to eq([])
    expect(other_session_can_lock?).to be(true)
  end

  it "waits for a session lock held by a process running the earlier release" do
    stub_const("#{described_class}::LOCK_WAIT_SECONDS", 0.2)
    observer.exec_params("SELECT pg_advisory_lock($1::bigint)", [ key ])
    entered = false

    expect { described_class.with_item_lock(item_id) { entered = true } }
      .to raise_error(TimeTracking::Client::Error, "Another payment transition is in progress; refresh and retry")
    expect(entered).to be(false)
    observer.exec_params("SELECT pg_advisory_unlock($1::bigint)", [ key ])
    expect(described_class.with_item_lock(item_id) { :entered }).to eq(:entered)
  end

  it "frees the item when the holding connection is lost and still completes the caller's work" do
    allow(Rails.logger).to receive(:error)
    result = described_class.with_item_lock(item_id) do
      observer.exec_params("SELECT pg_terminate_backend($1, 2000)", [ item_lock_holders.first.first ])
      expect(other_session_can_lock?).to be(true)
      :completed
    end

    expect(result).to eq(:completed)
    expect(Rails.logger).to have_received(:error).with(/lock #{key} ended before release/)
    expect(item_lock_holders).to eq([])
  end

  it "bounds how long a hung holder can keep the item" do
    stub_const("DedicatedAdvisoryLock::MAX_HOLD", "300ms")
    allow(Rails.logger).to receive(:error)
    described_class.with_item_lock(item_id) do
      sleep 0.8
      expect(item_lock_holders).to eq([])
    end

    expect(Rails.logger).to have_received(:error).with(/lock #{key} ended before release/)
  end
end
