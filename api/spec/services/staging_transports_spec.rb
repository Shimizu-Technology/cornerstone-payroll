# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe "staging transport boundaries" do
  around do |example|
    old = ENV.to_h
    ENV["DEPLOYMENT_ENV"] = "staging"
    ENV["STAGING_TESTER_BINDINGS"] = '[{"user_id":1,"email":"leon@example.test","clerk_subject":"user_leon"}]'
    ENV["STAGING_INTEGRATION_HOSTS"] = "aire-staging.example.test"
    ENV["PRODUCTION_INTEGRATION_HOSTS"] = "aire.example.test"
    example.run
  ensure
    ENV.replace(old)
  end

  it "blocks unknown Net::HTTP transports before opening the socket" do
    # WebMock replaces Net::HTTP after Rails boot. Exercise the real class that
    # production uses, while forbidding any socket connection explicitly.
    WebMock.disable!
    http = Net::HTTP.new("production.example.test", 443)
    http.use_ssl = true
    expect(http).not_to receive(:connect)
    expect { http.request(Net::HTTP::Post.new("/")) }.to raise_error(StagingOutboundPolicy::Blocked)
  ensure
    WebMock.enable!
  end

  it "rejects storage construction and presigning with copied bucket credentials" do
    expect { ActiveStorage::Service::S3Service.new(bucket: "production", access_key_id: "copied", secret_access_key: "copied", region: "us-east-1") }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end

  it "blocks every AI entry point before processing files or sending requests" do
    expect(HTTParty).not_to receive(:post)
    expect { TimecardOcr::OcrService.new(nil).call }.to raise_error(StagingOutboundPolicy::Blocked, /AI/)
    expect { InvoiceAiPreviewService.new(company: nil, user: nil, session: nil, message: "test").call }.to raise_error(StagingOutboundPolicy::Blocked, /AI/)
    expect { PayrollIntake::AiExtractor.new(source_type: "test", adapter: nil).call }.to raise_error(StagingOutboundPolicy::Blocked, /AI/)
  end

  it "blocks tax ingest even if a destination was copied" do
    ENV["CST_INGEST_URL"] = "https://tax.example.test/ingest"
    expect(PayrollTaxSyncService.configured?).to eq(false)
    expect { PayrollTaxSyncService.new(nil).sync! }.to raise_error(StagingOutboundPolicy::Blocked, /disabled in staging/)
  end

  it "blocks Clerk invitations and revocations for non-testers" do
    expect { ClerkInvitationService.new.create_invitation(email: "employee@example.test") }.to raise_error(StagingOutboundPolicy::Blocked)
    expect { ClerkInvitationService.new.revoke_invitation("copied-invitation") }.to raise_error(StagingOutboundPolicy::Blocked)
  end
end
