# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecentVerification, type: :controller do
  controller(ActionController::API) do
    include ClerkAuthenticatable
    include RecentVerification

    before_action :require_recent_verification!

    def create
      head :no_content
    end

    private

    def auth_disabled? = false
  end

  let(:issuer) { "https://payroll-step-up.clerk.accounts.dev" }
  let(:origin) { "https://payroll.example.test" }
  let(:signing_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk) { JWT::JWK.new(signing_key) }

  before do
    verifier = ClerkTokenVerifier.new(
      env: { "CLERK_ISSUER" => issuer, "CLERK_AUTHORIZED_PARTIES" => origin },
      cache: ActiveSupport::Cache::MemoryStore.new,
      http_get: ->(_uri) { [ 200, { "keys" => [ jwk.export.deep_stringify_keys ] } ] }
    )
    allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
  end

  def submit(role:, ages:, enrollment: nil)
    user = create(:user, role: role, clerk_id: "user_step_up")
    claims = { sub: user.clerk_id, iss: issuer, azp: origin, exp: 5.minutes.from_now.to_i, fva: ages }
    claims[:two_factor_enabled] = enrollment unless enrollment.nil?
    token = JWT.encode(claims, signing_key, "RS256", kid: jwk.kid)
    request.headers["Authorization"] = "Bearer #{token}"
    post :create
  end

  def expect_reverification(level)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq(
      "clerk_error" => {
        "type" => "forbidden",
        "reason" => "reverification-error",
        "metadata" => { "reverification" => { "level" => level, "afterMinutes" => 10 } }
      }
    )
  end

  it "permits a fresh first factor for an employee-only user without enrollment" do
    submit(role: :portal_employee, ages: [ 3, -1 ])
    expect(response).to have_http_status(:no_content)
  end

  it "requires a fresh first factor for an employee-only user with an old first factor" do
    submit(role: :portal_employee, ages: [ 25, -1 ], enrollment: false)
    expect_reverification("first_factor")
  end

  [ :admin, :client, :portal_employee ].each do |role|
    it "requires second-factor reverification for enrolled #{role} users with an old second factor" do
      submit(role: role, ages: [ 3, 11 ], enrollment: true)
      expect_reverification("second_factor")
    end

    it "permits a fresh second factor for enrolled #{role} users" do
      submit(role: role, ages: [ 25, 10 ], enrollment: true)
      expect(response).to have_http_status(:no_content)
    end
  end

  it "keeps second-factor step-up for enrolled staff even when global enforcement is off" do
    allow(MfaPolicy).to receive(:enabled?).and_return(false)
    submit(role: :admin, ages: [ 1, 11 ], enrollment: true)
    expect_reverification("second_factor")
  end

  [ :admin, :client ].each do |role|
    it "sends unenrolled #{role} users to enrollment instead of a prompt that can't succeed" do
      submit(role: role, ages: [ 0, -1 ], enrollment: false)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq(
        "error" => "Set up two-step sign-in to make this change.",
        "code" => "mfa_enrollment_required"
      )
    end
  end

  it "does not let the new-device email code stand in for enrollment" do
    submit(role: :admin, ages: [ 1, 0 ])
    expect(response.parsed_body["code"]).to eq("mfa_enrollment_required")
  end

  it "permits a fresh first factor for the legacy employee role" do
    submit(role: :employee, ages: [ 3, -1 ])
    expect(response).to have_http_status(:no_content)
  end

  it "asks the legacy employee role for a fresh first factor, not a second factor" do
    submit(role: :employee, ages: [ 25, -1 ], enrollment: false)
    expect_reverification("first_factor")
  end
end
