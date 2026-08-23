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

  def client_for(source, policy: destination_policy, http_factory: nil, monotonic_clock: nil, timeout_runner: nil)
    described_class.new(
      source,
      destination_policy: policy,
      http_factory: http_factory,
      monotonic_clock: monotonic_clock,
      timeout_runner: timeout_runner
    )
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
end
