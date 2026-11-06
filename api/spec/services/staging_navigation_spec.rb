# frozen_string_literal: true

require "rails_helper"

RSpec.describe "staging browser authorization destinations" do
  around do |example|
    old = ENV.to_h
    ENV["DEPLOYMENT_ENV"] = "staging"
    ENV["STAGING_AIRE_FRONTEND_ORIGIN"] = "https://aire-web-staging.example.test"
    ENV["STAGING_PAYROLL_FRONTEND_ORIGIN"] = "https://payroll-web-staging.example.test"
    ENV["PRODUCTION_FRONTEND_HOSTS"] = "custom-production.example.test"
    ENV["AIRE_ACCOUNT_LINK_ALLOWED_HOSTS"] = "aire-services-guam.netlify.app"
    example.run
  ensure
    ENV.replace(old)
  end

  it "rejects copied account-link URLs even when the legacy production allowlist permits them" do
    source = TimeTrackingSource.new(name: "AIRE", source_type: "aire_services", base_url: "https://aire-api-staging.example.test", authorization_origin: "https://aire-web-staging.example.test")
    client = TimeTracking::Client.new(source)
    expect { client.send(:validate_account_link_authorization_url!, { "authorization_url" => "https://aire-services-guam.netlify.app/admin/payroll-link?token=private" }) }.to raise_error(StagingOutboundPolicy::Blocked)
    expect { client.send(:validate_account_link_authorization_url!, { "authorization_url" => "https://aire-web-staging.example.test/admin/payroll-link?token=synthetic" }) }.not_to raise_error
  end

  it "rejects saved production authorization origins and custom production aliases" do
    expect(TimeTracking::Connector.authorization_origin_allowed?("https://app.aireservicesguam.com")).to eq(false)
    expect { StagingOutboundPolicy.frontend_origin!("https://custom-production.example.test") }.to raise_error(StagingOutboundPolicy::Blocked)
  end

  it "returns false rather than raising for blocked source configuration" do
    expect(TimeTracking::DestinationPolicy.production_configuration_valid?(sources: [ TimeTrackingSource.new(base_url: "https://production.example.test") ])).to eq(false)
  end
end
