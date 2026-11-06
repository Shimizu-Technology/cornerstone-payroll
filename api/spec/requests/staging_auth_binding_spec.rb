# frozen_string_literal: true

require "rails_helper"

RSpec.describe "staging authenticated tester binding", type: :request do
  around do |example|
    old = ENV.to_h
    ENV["AUTH_ENABLED"] = "true"
    ENV["DEPLOYMENT_ENV"] = "staging"

    example.run
  ensure
    ENV.replace(old)
  end

  let(:user) { create(:user, email: "leon@example.test", clerk_id: "user_boundtester") }

  def verify_subject(subject)
    if defined?(ClerkAuth)
      allow(ClerkAuth).to receive(:verify).and_return({ "sub" => subject, "email" => user.email })
    else
      allow_any_instance_of(Api::V1::AuthController).to receive(:verify_clerk_token).and_return({ "sub" => subject, "email" => user.email })
    end
  end

  it "rejects a subject without a local binding instead of email-provisioning it" do
    ENV["STAGING_TESTER_BINDINGS"] = [ { user_id: user.id, email: user.email, clerk_subject: "user_unbound" } ].to_json
    verify_subject("user_unbound")
    original = user.clerk_id
    get "/api/v1/auth/me", headers: { "Authorization" => "Bearer synthetic" }
    expect(response).to have_http_status(:forbidden)
    expect(user.reload.clerk_id).to eq(original)
  end

  it "requires the local ID as well as email and subject" do
    ENV["STAGING_TESTER_BINDINGS"] = [ { user_id: user.id + 1_000_000, email: user.email, clerk_subject: user.clerk_id } ].to_json
    verify_subject(user.clerk_id)
    get "/api/v1/auth/me", headers: { "Authorization" => "Bearer synthetic" }
    expect(response).to have_http_status(:forbidden)
  end

  it "accepts only the exact explicitly bound local tester" do
    ENV["STAGING_TESTER_BINDINGS"] = [ { user_id: user.id, email: user.email, clerk_subject: user.clerk_id } ].to_json
    verify_subject(user.clerk_id)
    get "/api/v1/auth/me", headers: { "Authorization" => "Bearer synthetic" }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("user", "id")).to eq(user.id)
  end
  context "with shared production identities" do
    before do
      ENV["STAGING_SHARES_PRODUCTION_CLERK"] = "true"
      ENV["STAGING_SHARES_PRODUCTION_STORAGE"] = "true"
      ENV["STAGING_STORAGE_WRITE_PREFIX"] = "staging/2026-10-25/"
      ENV["STAGING_TESTER_BINDINGS"] = [ { user_id: user.id, email: user.email, clerk_subject: user.clerk_id } ].to_json
    end

    it "accepts the bound production subject and refuses any other production user" do
      verify_subject(user.clerk_id)
      get "/api/v1/auth/me", headers: { "Authorization" => "Bearer synthetic" }
      expect(response).to have_http_status(:ok)
      verify_subject("user_otherproduction")
      get "/api/v1/auth/me", headers: { "Authorization" => "Bearer synthetic" }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
