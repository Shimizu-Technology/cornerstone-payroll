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

  it "logs adapter failures without making a committed deactivation look reversible" do
    allow(matching_connections).to receive(:disconnect).and_raise(StandardError, "adapter unavailable")
    allow(Rails.logger).to receive(:error)

    expect(described_class.disconnect_user(user)).to eq(false)
    expect(Rails.logger).to have_received(:error).with(include("user=#{user.id}", "adapter unavailable"))
  end
end
