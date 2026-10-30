# frozen_string_literal: true

require "rails_helper"

RSpec.describe "staging identity and deployment selection" do
  %w[stagin stagng Staging].each do |value|
    it "rejects deployment typo #{value}" do
      expect { StagingOutboundPolicy.validate!(env: { "DEPLOYMENT_ENV" => value }) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /DEPLOYMENT_ENV/)
    end
  end

  it "rejects whitespace flags and requires a positive production assertion" do
    expect { StagingOutboundPolicy.validate!(env: { "DEPLOYMENT_ENV" => "Staging " }) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /DEPLOYMENT_ENV/)
    expect { StagingOutboundPolicy.validate_deployment!(env: {}, environment: "production") }.to raise_error(StagingOutboundPolicy::ConfigurationError, /DEPLOYMENT_ENV=production/)
    expect(StagingOutboundPolicy.validate_deployment!(env: { "DEPLOYMENT_ENV" => "production" }, environment: "production")).to eq(true)
    expect(StagingOutboundPolicy.validate_deployment!(env: {}, environment: "test")).to eq(true)
  end

  it "requires explicit unique local-ID, email and subject triples" do
    env = { "DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => "enabled", "STAGING_TESTER_BINDINGS" => '{"leon@example.test":"user_unrelated"}' }
    expect { StagingOutboundPolicy.bindings(env) }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end

  it "requires verified provider primary email and refuses another local subject owner before writes" do
    user = create(:user, email: "leon@example.test")
    original_subject = user.clerk_id
    env = { "DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => "enabled", "STAGING_TESTER_BINDINGS" => [ { user_id: user.id, email: user.email, clerk_subject: "user_newstaging" } ].to_json, "CLERK_SECRET_KEY" => "sk_test_synthetic" }
    allow(HTTParty).to receive(:get).and_return(double(success?: true, parsed_response: { "id" => "user_newstaging", "primary_email_address_id" => "email_1", "email_addresses" => [ { "id" => "email_1", "email_address" => "outsider@example.test", "verification" => { "status" => "verified" } } ] }))
    expect { StagingTesterIdentity.verify!(env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /verified primary/)
    expect(user.reload.clerk_id).to eq(original_subject)
    create(:user, clerk_id: "user_newstaging")
    expect(HTTParty).not_to receive(:get)
    expect { StagingTesterIdentity.verify!(env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /another local user/)
  end

  it "requires a verified primary address, then accepts its exact owner" do
    user = create(:user, email: "chels@example.test")
    records = [ { user_id: user.id, email: user.email, clerk_subject: "user_chelsstaging" } ]
    env = { "DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => "enabled", "STAGING_TESTER_BINDINGS" => records.to_json, "CLERK_SECRET_KEY" => "sk_test_synthetic" }
    data = { "id" => "user_chelsstaging", "primary_email_address_id" => "primary", "email_addresses" => [ { "id" => "primary", "email_address" => user.email, "verification" => { "status" => "unverified" } } ] }
    allow(HTTParty).to receive(:get).and_return(double(success?: true, parsed_response: data))
    expect { StagingTesterIdentity.verify!(env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /verified primary/)
    data["email_addresses"].first["verification"]["status"] = "verified"
    expect(StagingTesterIdentity.verify!(env: env)).to eq(records.map(&:stringify_keys))
    env["STAGING_TESTER_BINDINGS"] = [ records.first.merge(user_id: user.id + 1_000_000) ].to_json
    expect { StagingTesterIdentity.verify!(env: env) }.to raise_error(StagingOutboundPolicy::ConfigurationError, /exact local user/)
  end

  it "accepts only an exact bound local user at runtime" do
    env = { "DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => "enabled", "STAGING_TESTER_BINDINGS" => [ { user_id: 123, email: "leon@example.test", clerk_subject: "user_leon" } ].to_json }
    expect(StagingOutboundPolicy.tester?(user_id: 123, email: "leon@example.test", id: "user_leon", env: env)).to eq(true)
    expect(StagingOutboundPolicy.tester?(user_id: 456, email: "leon@example.test", id: "user_leon", env: env)).to eq(false)
  end
end
