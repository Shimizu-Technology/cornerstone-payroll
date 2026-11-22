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
    expect { ActiveStorage::Service::StagingS3Service.new(bucket: "production", access_key_id: "copied", secret_access_key: "copied", region: "us-east-1") }.to raise_error(StagingOutboundPolicy::ConfigurationError)
  end

  it "blocks every AI entry point before processing files or sending requests" do
    expect(HTTParty).not_to receive(:post)
    expect { TimecardOcr::OcrService.new(nil).call }.to raise_error(StagingOutboundPolicy::Blocked, /AI/)
    expect { InvoiceAiPreviewService.new(company: nil, user: nil, session: nil, message: "test").call }.to raise_error(StagingOutboundPolicy::Blocked, /AI/)
    expect { PayrollIntake::AiExtractor.new(source_type: "test", adapter: nil).call }.to raise_error(StagingOutboundPolicy::Blocked, /AI/)
  end

  it "blocks Clerk invitations and revocations for non-testers" do
    expect { ClerkInvitationService.new.create_invitation(email: "employee@example.test") }.to raise_error(StagingOutboundPolicy::Blocked)
    expect { ClerkInvitationService.new.revoke_invitation("copied-invitation") }.to raise_error(StagingOutboundPolicy::Blocked)
  end

  it "limits Clerk invitation status lookups to a named tester's exact invitation ID" do
    tester = create(:user, email: "leon@example.test", clerk_id: "user_leon", clerk_invitation_id: "inv_tester")
    ENV["STAGING_TESTER_BINDINGS"] = [ { user_id: tester.id, email: tester.email, clerk_subject: tester.clerk_id } ].to_json

    endpoint = "/v1/invitations"
    allowed = Net::HTTP::Get.new("#{endpoint}?query=inv_tester&limit=10")
    expect { StagingOutboundPolicy.clerk_request!(allowed, endpoint, ENV) }.not_to raise_error

    [ "", "?query=inv_other&limit=10", "?query=leon@example.test", "?query=inv_tester&query=inv_other" ].each do |query|
      request = Net::HTTP::Get.new(endpoint + query)
      expect { StagingOutboundPolicy.clerk_request!(request, endpoint, ENV) }.to raise_error(StagingOutboundPolicy::Blocked)
    end
  end
end
