# frozen_string_literal: true

require "rails_helper"

RSpec.describe RackAttackStore do
  it "uses a local counter without configuring Redis" do
    expect(described_class.build(" ")).to equal(described_class::MEMORY)
  end

  [ "https://password@example.com", "redis://example.com/invalid-db" ].each do |url|
    it "rejects an invalid shared URL without logging its value" do
      expect(Rails.logger).to receive(:warn).with("[Rack::Attack] RACK_ATTACK_REDIS_URL is invalid. Using process-local counters.")
      expect(described_class.build(url)).to equal(described_class::MEMORY)
    end
  end

  it "uses the shared count, falls back to expiring local counts, and retries Redis after a short cooldown" do
    shared = instance_double(ActiveSupport::Cache::RedisCacheStore)
    store = RackAttackStore::Failover.new(shared, described_class::MEMORY)
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(10, 11, 12, 16)
    expect(shared).to receive(:increment).with("key", 1, expires_in: 60).exactly(3).times.and_return(42, nil, 43)
    expect(Rails.logger).to receive(:warn).with(/Shared counters unavailable/).once

    expect(Array.new(4) { store.increment("key", 1, expires_in: 60) }).to eq([ 42, 1, 2, 43 ])
  end
end
