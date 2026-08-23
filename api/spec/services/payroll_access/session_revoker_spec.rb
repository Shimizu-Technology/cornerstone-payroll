# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollAccess::SessionRevoker do
  let(:user) { create(:user) }
  let(:remote_connections) { double("remote connections") }
  let(:matching_connections) { double("matching connections") }

  before do
    allow(ActionCable.server).to receive(:remote_connections).and_return(remote_connections)
    allow(remote_connections).to receive(:where).with(current_user: user).and_return(matching_connections)
  end

  it "disconnects every matching connection without allowing reconnect" do
    expect(matching_connections).to receive(:disconnect).with(reconnect: false)

    expect(described_class.disconnect_user(user)).not_to eq(false)
  end

  it "raises adapter failures so the revocation job retries them" do
    allow(matching_connections).to receive(:disconnect).and_raise(StandardError, "adapter unavailable")

    expect { described_class.disconnect_user(user) }.to raise_error(StandardError, "adapter unavailable")
  end
end
