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

  context "when an active accountant's assignments change after subscribing" do
    include ActiveSupport::Testing::TimeHelpers

    let(:user) { create(:user, role: :accountant, company: company, organization: organization) }
    let(:target_company) { create(:company, organization: organization) }
    let(:remaining_company) { create(:company, organization: organization) }
    let!(:home_assignment) { create(:company_assignment, user: user, company: company) }
    let!(:remaining_assignment) { create(:company_assignment, user: user, company: remaining_company) }
    let!(:target_assignment) do
      create(:company_assignment, user: user, company: target_company, expires_at: 1.minute.from_now)
    end

    before do
      stub_connection(current_user: user, current_company: target_company)
      subscribe
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(target_company)
      # The real subscription's access check seeds the long-lived user's memo.
      expect(user.accessible_company_ids).to contain_exactly(company.id, remaining_company.id, target_company.id)
      allow(subscription).to receive(:transmit).and_call_original
      allow(subscription).to receive(:stop_all_streams).and_call_original
      connection.define_singleton_method(:close) { |**| }
      allow(connection).to receive(:close)
    end

    def expect_revoked_target_and_authorized_remaining_companies
      expect(User.find(user.id)).to be_active
      expect(User.find(user.id).accessible_company_ids).to contain_exactly(company.id, remaining_company.id)
      subscription.send(:transmit_if_authorized, { "event" => "thread_updated", "scope" => "revoked_target" })
      expect(subscription).not_to have_received(:transmit)
      expect(subscription).to have_received(:stop_all_streams)
      expect(connection).to have_received(:close).with(reason: "Payroll access revoked", reconnect: false)

      [ company, remaining_company ].each do |allowed_company|
        stub_connection(current_user: user, current_company: allowed_company)
        subscribe
        expect(subscription).to be_confirmed
        allow(subscription).to receive(:transmit).and_call_original
        subscription.send(:transmit_if_authorized, { "event" => "thread_updated", "scope" => "retained_company" })
        expect(subscription).to have_received(:transmit).with("event" => "thread_updated", "scope" => "retained_company")
      end
    end

    it "does not deliver target-company data after its assignment is removed" do
      target_assignment.destroy!

      expect_revoked_target_and_authorized_remaining_companies
    end

    it "does not deliver target-company data after its assignment expires" do
      travel_to(target_assignment.expires_at + 1.second) do
        expect_revoked_target_and_authorized_remaining_companies
      end
    end
  end

  it "closes a stale socket when its user was deleted" do
    subscribe
    allow(subscription).to receive(:stop_all_streams).and_call_original
    connection.define_singleton_method(:close) { |**| }
    allow(connection).to receive(:close)
    allow(subscription).to receive(:transmit).and_call_original
    user.destroy!

    subscription.send(:transmit_if_authorized, { "event" => "thread_updated" })

    expect(subscription).not_to have_received(:transmit)
    expect(subscription).to have_received(:stop_all_streams)
    expect(connection).to have_received(:close).with(reason: "Payroll access revoked", reconnect: false)
  end
end
