# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientInboxChannel, type: :channel do
  let(:company) { create(:company) }
  let(:staff) { create(:user, company: company, organization: company.organization, role: :manager, platform_owner: false) }

  it "streams only generic invalidation signals to payroll staff" do
    stub_connection current_user: staff, current_company: company
    subscribe
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(company.organization)
  end

  it "transmits generic invalidation and closes a stale staff socket after revocation" do
    stub_connection current_user: staff, current_company: company
    subscribe
    allow(subscription).to receive(:transmit)
    subscription.send(:transmit_if_authorized)
    expect(subscription).to have_received(:transmit).with({ event: "work_changed" })
    staff.update_columns(role: User.roles.fetch("client"))
    connection.define_singleton_method(:close) { |**| }
    allow(connection).to receive(:close)
    subscription.send(:transmit_if_authorized)
    expect(connection).to have_received(:close).with(reason: "Payroll access revoked", reconnect: false)
    expect(subscription).to have_received(:transmit).once
  end

  it "rejects clients" do
    staff.update!(role: :client)
    stub_connection current_user: staff, current_company: company
    subscribe
    expect(subscription).to be_rejected
  end

  it "rejects inactive users" do
    staff.update!(active: false)
    stub_connection current_user: staff, current_company: company
    subscribe
    expect(subscription).to be_rejected
  end
end
