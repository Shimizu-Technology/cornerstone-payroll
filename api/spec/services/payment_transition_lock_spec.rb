# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::PaymentCancellationBridge do
  self.use_transactional_tests = false
  it "serializes concurrent native and source transitions and releases the session lock on an exception" do
    item_id = SecureRandom.random_number(1_000_000_000) + 1
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
    release << true
    expect(first.value).to eq("Synthetic lost acknowledgement")
    second.join(3)
    expect(second.alive?).to be(false)
    expect(second_entered.pop).to be(true)
    ApplicationRecord.connection_pool.with_connection do |connection|
      expect(connection.select_value("SELECT pg_try_advisory_lock(#{4_100_000_000_000_000_000 + item_id})")).to be(true)
      connection.select_value("SELECT pg_advisory_unlock(#{4_100_000_000_000_000_000 + item_id})")
    end
  ensure
    release << true if first&.alive?
    first&.join(3)
    second&.join(3)
  end
end
