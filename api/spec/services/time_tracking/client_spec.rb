# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe TimeTracking::Client do
  let(:destination_policy) do
    TimeTracking::DestinationPolicy.new(
      environment: "test",
      resolver: ->(_host) { [ "8.8.8.8" ] }
    )
  end

  def client_for(source, delegation: nil, policy: destination_policy, http_factory: nil, monotonic_clock: nil, timeout_runner: nil)
    described_class.new(
      source,
      delegation: delegation,
      destination_policy: policy,
      http_factory: http_factory,
      monotonic_clock: monotonic_clock,
      timeout_runner: timeout_runner
    )
  end

  describe "AIRE payroll cockpit" do
    let(:source) do
      create(
        :time_tracking_source,
        source_type: "aire_services",
        base_url: "https://time.example.com/client-a",
        shared_secret: "secret"
      )
    end
    let(:external_id) { SecureRandom.uuid }

    it "reads a period and literal time entries with bounded query parameters" do
      period_stub = stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/cockpit/periods/#{external_id}")
        .with(headers: { "X-Payroll-Shared-Secret" => "secret" })
        .to_return(status: 200, body: { payroll_period: { external_pay_period_id: external_id } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      entries_stub = stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/cockpit/time_entries")
        .with(
          query: hash_including(
            "external_pay_period_id" => external_id,
            "page" => "2",
            "per_page" => "25",
            "approval_status" => "pending"
          ),
          headers: { "X-Payroll-Shared-Secret" => "secret" }
        )
        .to_return(status: 200, body: { time_entries: [] }.to_json,
                   headers: { "Content-Type" => "application/json" })

      expect(client_for(source).payroll_cockpit_period(external_pay_period_id: external_id))
        .to include("payroll_period")
      expect(client_for(source).payroll_cockpit_time_entries(
        external_pay_period_id: external_id,
        page: 2,
        per_page: 25,
        approval_status: "pending"
      )).to eq("time_entries" => [])
      expect(period_stub).to have_been_requested.once
      expect(entries_stub).to have_been_requested.once
    end

    it "clamps cockpit pagination at the supported boundaries" do
      lower_stub = stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/cockpit/time_entries")
        .with(query: hash_including("external_pay_period_id" => external_id, "page" => "1", "per_page" => "1"))
        .to_return(status: 200, body: { time_entries: [] }.to_json,
                   headers: { "Content-Type" => "application/json" })
      upper_stub = stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/cockpit/time_entries")
        .with(query: hash_including("external_pay_period_id" => external_id, "page" => "3", "per_page" => "250"))
        .to_return(status: 200, body: { time_entries: [] }.to_json,
                   headers: { "Content-Type" => "application/json" })

      client_for(source).payroll_cockpit_time_entries(
        external_pay_period_id: external_id,
        page: 0,
        per_page: 0
      )
      client_for(source).payroll_cockpit_time_entries(
        external_pay_period_id: external_id,
        page: 3,
        per_page: 10_000
      )

      expect(lower_stub).to have_been_requested.once
      expect(upper_stub).to have_been_requested.once
    end

    it "sends delegated approval commands with both authentication layers" do
      delegation = create(
        :time_tracking_delegation,
        company: source.company,
        time_tracking_source: source,
        user: create(:user, company: source.company, organization: source.company.organization, role: "manager"),
        token: "operator-grant"
      )
      command_id = SecureRandom.uuid
      stub = stub_request(:post, "https://time.example.com/client-a/api/v1/payroll/cockpit/time_entries/42/approval")
        .with(
          headers: {
            "X-Payroll-Shared-Secret" => "secret",
            "X-Aire-Delegation-Token" => "operator-grant"
          },
          body: hash_including(
            "command_id" => command_id,
            "expected_version" => 3,
            "decision" => "approve",
            "reason" => "Verified by payroll"
          )
        )
        .to_return(status: 200, body: { time_entry: { id: "42" } }.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = client_for(source, delegation: delegation).approve_payroll_time_entry(
        entry_id: 42,
        command_id: command_id,
        expected_version: 3,
        decision: "approve",
        reason: "Verified by payroll"
      )

      expect(result.dig("time_entry", "id")).to eq("42")
      expect(stub).to have_been_requested.once
    end

    it "refuses to send a delegation token over non-loopback HTTP" do
      source.update!(base_url: "http://time.example.com/client-a")
      delegation = create(
        :time_tracking_delegation,
        company: source.company,
        time_tracking_source: source,
        user: create(:user, company: source.company, organization: source.company.organization, role: "manager"),
        token: "operator-grant"
      )

      expect do
        client_for(source, delegation: delegation).approve_payroll_time_entry(
          entry_id: 42,
          command_id: SecureRandom.uuid,
          expected_version: 3,
          decision: "approve",
          reason: "Verified by payroll"
        )
      end.to raise_error(TimeTracking::Client::Error, /require HTTPS/)
    end

    it "permits loopback HTTP for local cockpit development" do
      source.update!(base_url: "http://localhost:4101")
      delegation = create(
        :time_tracking_delegation,
        company: source.company,
        time_tracking_source: source,
        user: create(:user, company: source.company, organization: source.company.organization, role: "manager"),
        token: "operator-grant"
      )
      stub = stub_request(:post, "http://localhost:4101/api/v1/payroll/cockpit/time_entries/42/approval")
        .to_return(status: 200, body: { command: { replayed: false } }.to_json,
                   headers: { "Content-Type" => "application/json" })

      response = client_for(source, delegation: delegation).approve_payroll_time_entry(
        entry_id: 42,
        command_id: SecureRandom.uuid,
        expected_version: 3,
        decision: "approve",
        reason: "Verified by payroll"
      )

      expect(response.dig("command", "replayed")).to be(false)
      expect(stub).to have_been_requested.once
    end

    it "refuses delegated commands when the current operator has no token" do
      expect do
        client_for(source).finalize_payroll_cockpit_period(
          external_pay_period_id: external_id,
          command_id: SecureRandom.uuid,
          expected_version: 1,
          reason: "Cutoff review complete"
        )
      end.to raise_error(TimeTracking::Client::Error, /delegation is not configured/)
    end

    it "surfaces only bounded JSON operator errors from cockpit endpoints" do
      stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/cockpit/periods/#{external_id}")
        .to_return(
          status: 409,
          body: { error: "The period changed in AIRE" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect do
        client_for(source).payroll_cockpit_period(external_pay_period_id: external_id)
      end.to raise_error(TimeTracking::Client::Error) { |error|
        expect(error.response_status).to eq(409)
        expect(error.message).to eq("#{source.name}: The period changed in AIRE")
      }
    end

    it "does not surface non-object or non-JSON remote response bodies" do
      stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/cockpit/periods/#{external_id}")
        .to_return(status: 500, body: [ "internal-token" ].to_json,
                   headers: { "Content-Type" => "application/json" })

      expect do
        client_for(source).payroll_cockpit_period(external_pay_period_id: external_id)
      end.to raise_error(TimeTracking::Client::Error) { |error|
        expect(error.message).to include("HTTP 500")
        expect(error.message).not_to include("internal-token")
      }
    end

    it "rejects unsafe period and time entry identifiers before a request" do
      request = stub_request(:any, %r{time\.example\.com})

      expect do
        client_for(source).payroll_cockpit_period(external_pay_period_id: "../period")
      end.to raise_error(TimeTracking::Client::Error, /Invalid payroll calendar period ID/)
      expect do
        client_for(source, delegation: instance_double(TimeTrackingDelegation, token: "grant"))
          .approve_payroll_time_entry(
            entry_id: "../42",
            command_id: SecureRandom.uuid,
            expected_version: 1,
            decision: "approve",
            reason: "Verified"
          )
      end.to raise_error(TimeTracking::Client::Error, /Invalid AIRE time entry ID/)
      expect(request).not_to have_been_requested
    end

    it "suppresses oversized JSON and HTML error details" do
      period_url = "https://time.example.com/client-a/api/v1/payroll/cockpit/periods/#{external_id}"
      oversized_secret = "s" * (described_class::MAX_REMOTE_ERROR_BYTES + 1)
      stub_request(:get, period_url)
        .to_return(
          { status: 500, body: { error: oversized_secret }.to_json, headers: { "Content-Type" => "application/json" } },
          { status: 502, body: "<html>private upstream detail</html>", headers: { "Content-Type" => "text/html" } }
        )

      expect do
        client_for(source).payroll_cockpit_period(external_pay_period_id: external_id)
      end.to raise_error(TimeTracking::Client::Error) { |error|
        expect(error.message).to eq("#{source.name} returned HTTP 500")
        expect(error.message).not_to include(oversized_secret)
      }
      expect do
        client_for(source).payroll_cockpit_period(external_pay_period_id: external_id)
      end.to raise_error(TimeTracking::Client::Error) { |error|
        expect(error.message).to eq("#{source.name} returned HTTP 502")
        expect(error.message).not_to include("private upstream detail")
      }
    end
  end

  def configure_http_double(http, pinned_ip:, start_error: nil, response: nil)
    allow(http).to receive(:ipaddr=).with(pinned_ip)
    allow(http).to receive(:use_ssl=).with(true)
    allow(http).to receive(:use_ssl?).and_return(true)
    allow(http).to receive(:verify_mode=)
    allow(http).to receive(:verify_hostname=)
    allow(http).to receive(:min_version=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:write_timeout=)
    allow(http).to receive(:max_retries=)

    if start_error
      allow(http).to receive(:start).and_raise(start_error)
      allow(http).to receive(:request)
    else
      allow(http).to receive(:start).and_return(http)
      allow(http).to receive(:started?).and_return(true)
      allow(http).to receive(:finish)
      allow(http).to receive(:request).and_yield(response)
    end
  end

  describe "#publish_payroll_calendar_period" do
    it "uses the versioned AIRE calendar path, shared secret, PUT body, and idempotency key" do
      source = create(
        :time_tracking_source,
        source_type: "aire_services",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      external_id = SecureRandom.uuid
      publication_id = SecureRandom.uuid
      payload = { "schema_version" => "1.0", "publication_id" => publication_id }
      stub = stub_request(:put, "https://time.example.com/api/v1/payroll/calendar_periods/#{external_id}")
        .with(
          body: payload.to_json,
          headers: {
            "X-Shared-Secret" => "secret",
            "X-Payroll-Shared-Secret" => "secret",
            "Idempotency-Key" => publication_id
          }
        )
        .to_return(
          status: 201,
          body: { payroll_calendar_period: { external_pay_period_id: external_id } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = client_for(source).publish_payroll_calendar_period(
        external_pay_period_id: external_id,
        payload: payload,
        idempotency_key: publication_id
      )

      expect(result.dig("payroll_calendar_period", "external_pay_period_id")).to eq(external_id)
      expect(stub).to have_been_requested.once
    end

    it "retains the response status without exposing a rejected JSON body" do
      source = create(:time_tracking_source, source_type: "aire_services", base_url: "https://time.example.com")
      external_id = SecureRandom.uuid
      stub_request(:put, "https://time.example.com/api/v1/payroll/calendar_periods/#{external_id}")
        .to_return(
          status: 409,
          body: { error: "secret source details" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect do
        client_for(source).publish_payroll_calendar_period(
          external_pay_period_id: external_id,
          payload: {},
          idempotency_key: SecureRandom.uuid
        )
      end.to raise_error(TimeTracking::Client::Error) { |error|
        expect(error.response_status).to eq(409)
        expect(error.message).to include("HTTP 409")
        expect(error.message).not_to include("secret source details")
      }
    end
  end

  describe "#time_summary" do
    it "builds the time summary URL when the configured source base URL has no path" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Root Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      stub = stub_request(:get, "https://time.example.com/api/v1/payroll/time_summary")
        .with(query: { start_date: "2026-05-01", end_date: "2026-05-15" })
        .to_return(status: 200, body: { employees: [] }.to_json, headers: { "Content-Type" => "application/json" })

      client_for(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

      expect(stub).to have_been_requested
    end

    it "preserves a path prefix in the configured source base URL" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Prefixed Source",
        source_type: "custom",
        base_url: "https://time.example.com/client-a",
        shared_secret: "secret"
      )
      stub = stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/time_summary")
        .with(
          query: { start_date: "2026-05-01", end_date: "2026-05-15" },
          headers: { "X-Shared-Secret" => "secret", "X-Payroll-Shared-Secret" => "secret" }
        )
        .to_return(status: 200, body: { employees: [] }.to_json, headers: { "Content-Type" => "application/json" })

      client_for(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

      expect(stub).to have_been_requested
    end

    it "rejects a known source when the endpoint responds as a different system" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      stub_request(:get, "https://time.example.com/api/v1/payroll/time_summary")
        .with(query: { start_date: "2026-05-01", end_date: "2026-05-15" })
        .to_return(status: 200, body: { source: "cornerstone_tax", employees: [] }.to_json, headers: { "Content-Type" => "application/json" })

      expect do
        client_for(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /responded as cornerstone_tax, expected aire_services/)
    end

    it "rejects a known source when the endpoint omits source identity" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      stub_request(:get, "https://time.example.com/api/v1/payroll/time_summary")
        .with(query: { start_date: "2026-05-01", end_date: "2026-05-15" })
        .to_return(status: 200, body: { employees: [] }.to_json, headers: { "Content-Type" => "application/json" })

      expect do
        client_for(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /omitted source identity/)
    end

    it "rejects a known source when the endpoint returns a null source identity" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      stub_request(:get, "https://time.example.com/api/v1/payroll/time_summary")
        .with(query: { start_date: "2026-05-01", end_date: "2026-05-15" })
        .to_return(status: 200, body: { source: nil, employees: [] }.to_json, headers: { "Content-Type" => "application/json" })

      expect do
        client_for(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /omitted source identity/)
    end

    it "allows custom sources to return any compatible source identity" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Custom",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      stub_request(:get, "https://time.example.com/api/v1/payroll/time_summary")
        .with(query: { start_date: "2026-05-01", end_date: "2026-05-15" })
        .to_return(status: 200, body: { source: "cornerstone_tax", employees: [] }.to_json, headers: { "Content-Type" => "application/json" })

      payload = client_for(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

      expect(payload["source"]).to eq("cornerstone_tax")
    end

    it "rejects every DNS answer when any answer is non-public before sending the secret" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Mixed DNS",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      policy = TimeTracking::DestinationPolicy.new(
        environment: "test",
        resolver: ->(_host) { [ "8.8.8.8", "169.254.169.254" ] }
      )
      request = stub_request(:get, %r{time\.example\.com})

      expect do
        client_for(source, policy: policy).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /non-public address/)
      expect(request).not_to have_been_requested
    end

    it "rejects a declared response larger than the import limit" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Oversized Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      stub_request(:get, "https://time.example.com/api/v1/payroll/time_summary")
        .with(query: { start_date: "2026-05-01", end_date: "2026-05-15" })
        .to_return(
          status: 200,
          body: "{}",
          headers: {
            "Content-Type" => "application/json",
            "Content-Length" => (described_class::MAX_RESPONSE_BYTES + 1).to_s
          }
        )

      expect do
        client_for(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /response exceeded/)
    end

    it "does not include a rejected response body in an operator-facing error" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Failing Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      stub_request(:get, "https://time.example.com/api/v1/payroll/time_summary")
        .with(query: { start_date: "2026-05-01", end_date: "2026-05-15" })
        .to_return(status: 500, body: "internal-token=do-not-leak", headers: { "Content-Type" => "text/plain" })

      expect do
        client_for(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error) { |error|
        expect(error.message).to include("HTTP 500")
        expect(error.message).not_to include("internal-token")
      }
    end

    it "tries every inspected address until one establishes a connection" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Multi-address Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      policy = TimeTracking::DestinationPolicy.new(
        environment: "test",
        resolver: ->(_host) { [ "8.8.4.1", "8.8.4.2", "8.8.4.3", "8.8.4.4", "8.8.8.8" ] }
      )
      failed_http_clients = 4.times.map { instance_double(Net::HTTP) }
      successful_http = instance_double(Net::HTTP)
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response["Content-Type"] = "application/json"
      allow(response).to receive(:read_body).and_yield('{"employees":[]}')
      failed_http_clients.each_with_index do |http, index|
        configure_http_double(http, pinned_ip: "8.8.4.#{index + 1}", start_error: Errno::ECONNREFUSED.new)
      end
      configure_http_double(successful_http, pinned_ip: "8.8.8.8", response: response)
      http_factory = instance_double(Proc)
      allow(http_factory).to receive(:call).and_return(*failed_http_clients, successful_http)

      payload = client_for(source, policy: policy, http_factory: http_factory)
        .time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

      expect(payload["employees"]).to eq([])
      failed_http_clients.each { |http| expect(http).not_to have_received(:request) }
      expect(successful_http).to have_received(:request).once
    end

    it "does not retry another address after a request begins" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Read Failure Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      policy = TimeTracking::DestinationPolicy.new(
        environment: "test",
        resolver: ->(_host) { [ "8.8.4.4", "8.8.8.8" ] }
      )
      first_http = instance_double(Net::HTTP)
      second_http = instance_double(Net::HTTP)
      configure_http_double(first_http, pinned_ip: "8.8.4.4", response: nil)
      allow(first_http).to receive(:request).and_raise(Net::ReadTimeout)
      http_factory = instance_double(Proc)
      allow(http_factory).to receive(:call).and_return(first_http, second_http)

      expect do
        client_for(source, policy: policy, http_factory: http_factory)
          .time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /Could not securely reach/)

      expect(http_factory).to have_received(:call).once
      expect(first_http).to have_received(:request).once
    end

    it "stops address fallback when the aggregate connection deadline expires" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Slow Multi-address Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      policy = TimeTracking::DestinationPolicy.new(
        environment: "test",
        resolver: ->(_host) { [ "8.8.4.4", "8.8.8.8" ] }
      )
      first_http = instance_double(Net::HTTP)
      second_http = instance_double(Net::HTTP)
      configure_http_double(first_http, pinned_ip: "8.8.4.4", start_error: Net::OpenTimeout.new)
      http_factory = instance_double(Proc)
      allow(http_factory).to receive(:call).and_return(first_http, second_http)
      monotonic_clock = instance_double(Proc)
      allow(monotonic_clock).to receive(:call).and_return(0.0, 0.0, 4.9, 5.0)

      expect do
        client_for(
          source,
          policy: policy,
          http_factory: http_factory,
          monotonic_clock: monotonic_clock
        ).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /Could not securely reach/)

      expect(first_http).to have_received(:open_timeout=).with(be_within(0.001).of(0.1))
      expect(http_factory).to have_received(:call).once
    end

    it "includes DNS resolution in the aggregate connection deadline" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "Slow DNS Source",
        source_type: "custom",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      policy = instance_double(TimeTracking::DestinationPolicy)
      allow(policy).to receive(:resolve_public_addresses!)
      timeout_runner = instance_double(Proc)
      allow(timeout_runner).to receive(:call).and_raise(Net::OpenTimeout)

      expect do
        client_for(source, policy: policy, timeout_runner: timeout_runner)
          .time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /Could not securely reach/)

      expect(timeout_runner).to have_received(:call).with(be_within(0.1).of(described_class::OPEN_TIMEOUT_SECONDS))
      expect(policy).not_to have_received(:resolve_public_addresses!)
    end
  end

  describe "#record_payroll_batch_processing_event" do
    it "posts an authenticated idempotent processing acknowledgement" do
      source = TimeTrackingSource.create!(
        company: create(:company),
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://time.example.com",
        shared_secret: "secret"
      )
      stub = stub_request(:post, "https://time.example.com/api/v1/payroll/batches/AIRE-PAY-123/processing_events")
        .with(
          headers: { "X-Payroll-Shared-Secret" => "secret", "Content-Type" => "application/json" },
          body: hash_including("event_id" => "event-1", "status" => "imported", "external_system" => "cornerstone_payroll")
        )
        .to_return(status: 201, body: { processing: { status: "imported" } }.to_json, headers: { "Content-Type" => "application/json" })

      client_for(source).record_payroll_batch_processing_event(
        batch_id: "AIRE-PAY-123",
        event_id: "event-1",
        status: "imported",
        occurred_at: "2026-09-02T01:00:00Z",
        external_pay_period_id: "42"
      )

      expect(stub).to have_been_requested.once
    end
  end

  describe "finalized payroll batches" do
    let(:source) do
      TimeTrackingSource.create!(
        company: create(:company),
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://time.example.com/client-a",
        shared_secret: "secret"
      )
    end

    it "discovers exact-date batches with both supported shared-secret headers" do
      stub = stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/batches")
        .with(
          query: { start_date: "2026-08-16", end_date: "2026-08-31" },
          headers: { "X-Shared-Secret" => "secret", "X-Payroll-Shared-Secret" => "secret" }
        )
        .to_return(status: 200, body: { payroll_batches: [] }.to_json, headers: { "Content-Type" => "application/json" })

      result = client_for(source).payroll_batches(start_date: "2026-08-16", end_date: "2026-08-31")

      expect(result).to eq("payroll_batches" => [])
      expect(stub).to have_been_requested.once
    end

    it "retrieves a stable batch ID and verifies source identity" do
      stub = stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/batches/AIRE-PAY-001")
        .to_return(
          status: 200,
          body: { source: "aire_services", batch_id: "AIRE-PAY-001" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = client_for(source).payroll_batch(batch_id: "AIRE-PAY-001")

      expect(result["batch_id"]).to eq("AIRE-PAY-001")
      expect(stub).to have_been_requested.once
    end

    it "rejects unsafe batch identifiers before making a request" do
      request = stub_request(:get, %r{time\.example\.com})

      [ "../admin", ".", "..." ].each do |batch_id|
        expect do
          client_for(source).payroll_batch(batch_id: batch_id)
        end.to raise_error(TimeTracking::Client::Error, /Invalid payroll batch ID/)
      end
      expect(request).not_to have_been_requested
    end

    it "rejects a malformed batch list" do
      stub_request(:get, "https://time.example.com/client-a/api/v1/payroll/batches")
        .with(query: { start_date: "2026-08-16", end_date: "2026-08-31" })
        .to_return(status: 200, body: { payroll_batches: {} }.to_json, headers: { "Content-Type" => "application/json" })

      expect do
        client_for(source).payroll_batches(start_date: "2026-08-16", end_date: "2026-08-31")
      end.to raise_error(TimeTracking::Client::Error, /invalid payroll batch list/)
    end
  end
end
