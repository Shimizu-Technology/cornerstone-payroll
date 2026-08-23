# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientPortalThreadChannel, type: :channel do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:user) { create(:user, company: company, organization: organization) }

  before do
    stub_connection(current_user: user, current_company: company)
  end

  it "confirms an authorized subscription" do
    subscribe

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(company)
  end

  it "rejects an inactive user's new subscription" do
    user.update_columns(active: false)

    subscribe

    expect(subscription).to be_rejected
  end

  it "transmits a broadcast only while local access remains authorized" do
    subscribe
    allow(subscription).to receive(:transmit)

    subscription.send(:transmit_if_authorized, { "event" => "thread_updated" })

    expect(subscription).to have_received(:transmit).with("event" => "thread_updated")
  end

  it "closes a stale socket instead of transmitting after deactivation" do
    subscribe
    allow(subscription).to receive(:stop_all_streams)
    connection.define_singleton_method(:close) { |**| }
    allow(connection).to receive(:close)
    allow(subscription).to receive(:transmit)
    user.update_columns(active: false)

    subscription.send(:transmit_if_authorized, { "event" => "thread_updated" })

    expect(subscription).not_to have_received(:transmit)
    expect(subscription).to have_received(:stop_all_streams)
    expect(connection).to have_received(:close).with(reason: "Payroll access revoked", reconnect: false)
  end
end
