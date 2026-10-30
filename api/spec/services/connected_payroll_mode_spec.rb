# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConnectedPayrollMode do
  it "fails closed in production for missing, empty, misspelled and unrecognized values" do
    [ nil, "", "ENABLED", "enable", "unknown" ].each do |value|
      env = { "DEPLOYMENT_ENV" => "production", "CONNECTED_PAYROLL_MODE" => value }
      expect(described_class.mode(env: env, environment: "test")).to eq("paused")
    end
    expect(described_class.mode(env: {}, environment: "production")).to eq("paused")
  end

  it "defaults development and test to enabled while honoring explicit pause" do
    %w[development test].each do |environment|
      expect(described_class.mode(env: {}, environment: environment)).to eq("enabled")
      expect(described_class.mode(env: { "CONNECTED_PAYROLL_MODE" => "paused" }, environment: environment)).to eq("paused")
    end
  end

  it "requires an explicit supported mode for staging" do
    [ nil, "", "unknown" ].each do |value|
      expect { described_class.validate!(env: { "DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => value }) }
        .to raise_error(described_class::ConfigurationError, /CONNECTED_PAYROLL_MODE/)
    end
    %w[enabled paused].each do |value|
      expect(described_class.validate!(env: { "DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => value })).to be(true)
      expect(described_class.mode(env: { "DEPLOYMENT_ENV" => "production", "CONNECTED_PAYROLL_MODE" => value })).to eq(value)
    end
  end
end
