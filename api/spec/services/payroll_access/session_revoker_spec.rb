# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollAccess::SessionRevoker do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:cable_server) do
    config = ActionCable::Server::Configuration.new
    config.logger = ActiveSupport::TaggedLogging.new(Logger.new(File::NULL))
    config.cable = { "adapter" => "test" }
    config.connection_class = -> { ApplicationCable::Connection }
    ActionCable::Server::Base.new(config: config)
  end
  let(:adapter) { cable_server.pubsub }

  before do
    allow(ActionCable).to receive(:server).and_return(cable_server)
    @subscriptions = []
    @received_messages = {}
  end

  after do
    @subscriptions.each { |channel, callback| adapter.unsubscribe(channel, callback) }
    cable_server.restart
    cable_server.event_loop.stop
  end

  def connected_as(person, company)
    connection = ApplicationCable::Connection.new(cable_server, Rack::MockRequest.env_for("/cable"))
    connection.current_user = person
    connection.current_company = company
    allow(connection).to receive(:close).and_call_original
    channel = connection.send(:internal_channel)
    received = Queue.new
    @received_messages[connection] = received
    callback = lambda do |message|
      connection.send(:process_internal_message, ActiveSupport::JSON.decode(message))
      received << message
    end
    subscribed = false
    adapter.subscribe(channel, callback, -> { subscribed = true })
    @subscriptions << [ channel, callback ]
    wait_for { subscribed }
    connection
  end

  def wait_for
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until yield
      raise "Action Cable callback did not complete" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end

  it "disconnects the actual company-scoped connection without allowing reconnect" do
    connection = connected_as(user, user.company)
    user.update!(active: false)

    expect(described_class.disconnect_user(user)).not_to eq(false)
    wait_for { adapter.broadcasts(connection.send(:internal_channel)).any? }
    wait_for { @received_messages[connection].size == 1 }
    expect(connection).to have_received(:close).with(reason: "remote", reconnect: false)
  end

  it "revokes switched and removed-assignment contexts without touching another user's connections" do
    former = create(:company, organization: user.organization)
    assignment = create(:company_assignment, user: user, company: former)
    other_user = create(:user, company: user.company, organization: user.organization)
    other_company = create(:company, organization: user.organization)
    current = connected_as(user, user.company)
    switched = connected_as(user, former)
    protected = connected_as(other_user, user.company)
    protected_other_company = connected_as(other_user, other_company)
    assignment.destroy!
    user.update!(active: false)

    2.times { described_class.disconnect_user(user) }

    [ current, switched ].each do |connection|
      wait_for { adapter.broadcasts(connection.send(:internal_channel)).size == 2 }
      wait_for { @received_messages[connection].size == 2 }
      expect(connection).to have_received(:close).with(reason: "remote", reconnect: false).at_least(:once)
    end
    expect(adapter.broadcasts(protected.send(:internal_channel))).to be_empty
    expect(protected).not_to have_received(:close)
    expect(adapter.broadcasts(protected_other_company.send(:internal_channel))).to be_empty
    expect(protected_other_company).not_to have_received(:close)
  end

  it "includes inactive and former cross-organization company contexts after a privilege change" do
    user.update!(role: :super_admin)
    former = create(:company, active: false)
    connection = connected_as(user, former)
    user.update!(role: :accountant, active: false)

    described_class.disconnect_user(user)

    wait_for { adapter.broadcasts(connection.send(:internal_channel)).any? }
    wait_for { @received_messages[connection].size == 1 }
    expect(connection).to have_received(:close).with(reason: "remote", reconnect: false)
  end

  it "includes an expired assignment when its user is subsequently revoked" do
    user.update!(role: :accountant)
    former = create(:company, organization: user.organization)
    assignment = create(:company_assignment, user: user, company: former, expires_at: 1.minute.from_now)
    connection = connected_as(user, former)

    travel_to(assignment.expires_at + 1.second) do
      expect(user.reload.accessible_company_ids).not_to include(former.id)
      user.update!(active: false)
      described_class.disconnect_user(user)
      wait_for { @received_messages[connection].size == 1 }
      expect(connection).to have_received(:close).with(reason: "remote", reconnect: false)
    end
  end

  it "disconnects existing contexts when organization access becomes inactive" do
    connection = connected_as(user, user.company)
    user.organization.update!(status: "inactive")
    expect(user.reload.payroll_access_allowed?).to be(false)

    described_class.disconnect_user(user)

    wait_for { @received_messages[connection].size == 1 }
    expect(connection).to have_received(:close).with(reason: "remote", reconnect: false)
  end

  it "delivers the native revocation job through the real adapter after deactivation" do
    connection = connected_as(user, user.company)
    user.update!(active: false)

    RevokePayrollAccessJob.perform_now(user.id)

    wait_for { @received_messages[connection].size == 1 }
    expect(connection).to have_received(:close).with(reason: "remote", reconnect: false)
  end

  it "also revokes a legacy user-only internal channel" do
    connection = connected_as(user, nil)

    described_class.disconnect_user(user)

    wait_for { adapter.broadcasts(connection.send(:internal_channel)).any? }
    wait_for { @received_messages[connection].size == 1 }
    expect(connection).to have_received(:close).with(reason: "remote", reconnect: false)
  end

  it "raises adapter failures so the revocation job retries them" do
    allow(adapter).to receive(:broadcast).and_raise(StandardError, "adapter unavailable")

    expect { described_class.disconnect_user(user) }.to raise_error(StandardError, "adapter unavailable")
  end
end
