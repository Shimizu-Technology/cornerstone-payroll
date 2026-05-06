# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe TimeTracking::Client do
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

      described_class.new(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

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

      described_class.new(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

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
        described_class.new(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")
      end.to raise_error(TimeTracking::Client::Error, /responded as cornerstone_tax, expected aire_services/)
    end

    it "accepts a known source when an older compatible endpoint omits source identity" do
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

      expect(Rails.logger).to receive(:warn).with(/omitted source identity/)

      payload = described_class.new(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

      expect(payload["employees"]).to eq([])
    end

    it "accepts a known source when an older compatible endpoint returns a null source identity" do
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

      expect(Rails.logger).to receive(:warn).with(/omitted source identity/)

      payload = described_class.new(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

      expect(payload["employees"]).to eq([])
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

      payload = described_class.new(source).time_summary(start_date: "2026-05-01", end_date: "2026-05-15")

      expect(payload["source"]).to eq("cornerstone_tax")
    end
  end
end
