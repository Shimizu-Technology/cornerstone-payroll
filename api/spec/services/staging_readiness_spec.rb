# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagingReadiness do
  it "keeps provider round trips out of the staging profile" do
    env = ENV.to_h.merge("DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => "enabled")
    allow(StagingOutboundPolicy).to receive(:validate!).with(env: env).and_return(true)
    env["USE_SOLID_QUEUE"] = "true"
    env["SOLID_QUEUE_IN_PUMA"] = "false"
    allow(ActiveJob::Base).to receive(:queue_adapter).and_return(ActiveJob::QueueAdapters::SolidQueueAdapter.new)
    allow(StagingQuarantine).to receive(:complete?).and_return(true)
    allow(SolidQueue::Process).to receive(:where).and_return(double(exists?: true))
    allow_any_instance_of(StagingReadiness).to receive(:decryptable?).and_return(true)
    expect(Net::HTTP).not_to receive(:start)
    storage_factory = -> { raise "Provider storage probe must not run" }
    http_get = ->(*) { raise "Provider HTTP probe must not run" }
    report = ProductionReadiness.new(env: env, storage_factory: storage_factory, http_get: http_get).run(live: true)
    expect(report.failures.map(&:name)).to eq([])
    expect(report.checks.map(&:name)).to include("staging containment settings", "persisted encrypted data can be decrypted", "Solid Queue worker has a recent heartbeat")
  end

  it "fails readiness for an uncontained clone or absent worker heartbeat" do
    allow(StagingOutboundPolicy).to receive(:validate!).and_return(true)
    allow(StagingQuarantine).to receive(:complete?).and_return(false)
    allow(SolidQueue::Process).to receive(:where).and_return(double(exists?: false))
    allow_any_instance_of(StagingReadiness).to receive(:decryptable?).and_return(true)
    report = described_class.new.run(live: true)
    expect(report).not_to be_passed
    expect(report.failures.map(&:name)).to include("staging clone containment manifest exists", "Solid Queue worker has a recent heartbeat")
  end

  it "rejects an incomplete durable queue schema" do
    allow(StagingOutboundPolicy).to receive(:validate!).and_return(true)
    allow(StagingCloneContainment).to receive(:queue_schema_complete?).and_return(false)
    report = described_class.new.run(live: false)
    expect(report.failures.map(&:name)).to include("complete Solid Queue schema exists")
  end

  it "rejects async execution even when a worker heartbeat exists" do
    allow(StagingOutboundPolicy).to receive(:validate!).and_return(true)
    allow(StagingQuarantine).to receive(:complete?).and_return(true)
    allow(SolidQueue::Process).to receive(:where).and_return(double(exists?: true))
    report = described_class.new.run(live: false)
    expect(report.failures.map(&:name)).to include("Solid Queue is the effective durable job adapter")
  end
end
