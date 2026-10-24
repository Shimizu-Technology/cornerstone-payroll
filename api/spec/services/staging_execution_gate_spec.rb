# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagingExecutionGate do
  it "allows only invocations containing exclusively approved maintenance tasks" do
    expect(described_class.maintenance_only?(%w[db:migrate solid_queue:setup staging:clone:configure])).to eq(true)
    expect(described_class.maintenance_only?(%w[db:version solid_queue:start])).to eq(false)
    expect(described_class.maintenance_only?(%w[staging:clone:verify unreviewed:execute])).to eq(false)
    expect(described_class.maintenance_only?([])).to eq(false)
  end

  it "blocks direct supervisor starts and queue submissions before containment" do
    allow(StagingOutboundPolicy).to receive(:staging?).and_return(true)
    allow(StagingQuarantine).to receive(:complete?).and_return(false)
    expect(SolidQueue::Supervisor).not_to receive(:new)
    expect { SolidQueue::Supervisor.start }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    adapter = ActiveJob::QueueAdapters::SolidQueueAdapter.new
    expect { adapter.enqueue(double) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    expect { adapter.enqueue_at(double, Time.current.to_f) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
    expect { adapter.enqueue_all([]) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end

  it "allows completed staging clones and leaves non-staging execution unchanged" do
    allow(StagingOutboundPolicy).to receive(:staging?).and_return(true)
    allow(StagingQuarantine).to receive(:complete?).and_return(true)
    expect(described_class.enforce!).to eq(true)
    allow(StagingOutboundPolicy).to receive(:staging?).and_return(false)
    expect(StagingQuarantine).not_to receive(:complete?)
    expect(described_class.enforce!).to eq(true)
  end
end
