# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalClientBootstrapDispatchJob, type: :job do
  it "recovers every due durable client-bootstrap dispatch" do
    allow(HistoricalClientBootstrapDispatch).to receive(:dispatch_pending!)

    described_class.perform_now

    expect(HistoricalClientBootstrapDispatch).to have_received(:dispatch_pending!)
  end
end
