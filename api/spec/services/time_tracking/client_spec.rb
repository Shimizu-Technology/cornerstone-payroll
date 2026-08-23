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

  def client_for(source, policy: destination_policy)
    described_class.new(source, destination_policy: policy)
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
  end
end
