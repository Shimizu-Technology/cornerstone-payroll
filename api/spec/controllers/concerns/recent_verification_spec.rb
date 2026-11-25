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

  def with_mfa(value)
    previous = ENV["REQUIRE_MFA"]
    value.nil? ? ENV.delete("REQUIRE_MFA") : ENV["REQUIRE_MFA"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("REQUIRE_MFA") : ENV["REQUIRE_MFA"] = previous
  end

  STEP_UP_ROLES = %i[super_admin admin org_admin manager accountant client employee portal_employee].freeze

  context "while MFA is off (REQUIRE_MFA unset or false)" do
    around { |example| with_mfa(nil) { example.run } }

    STEP_UP_ROLES.each do |role|
      it "permits a fresh first factor for #{role} users without enrollment" do
        submit(role: role, ages: [ 3, -1 ])
        expect(response).to have_http_status(:no_content)
      end

      it "asks #{role} users for a first-factor reverification, never enrollment, when it's old" do
        submit(role: role, ages: [ 25, -1 ], enrollment: false)
        expect_reverification("first_factor")
      end
    end

    it "treats REQUIRE_MFA=false like unset" do
      with_mfa("false") { submit(role: :admin, ages: [ 11, -1 ]) }
      expect_reverification("first_factor")
    end

    it "asks for a first factor even when the session holds a fresh second factor" do
      submit(role: :admin, ages: [ 25, 0 ], enrollment: true)
      expect_reverification("first_factor")
    end
  end

  context "when MFA is on (REQUIRE_MFA=true)" do
    around { |example| with_mfa("true") { example.run } }

    %i[admin client portal_employee employee].each do |role|
      it "requires second-factor reverification for enrolled #{role} users with an old second factor" do
        submit(role: role, ages: [ 3, 11 ], enrollment: true)
        expect_reverification("second_factor")
      end

      it "permits a fresh second factor for enrolled #{role} users" do
        submit(role: role, ages: [ 25, 10 ], enrollment: true)
        expect(response).to have_http_status(:no_content)
      end
    end

    %i[admin client portal_employee employee].each do |role|
      it "never accepts a first factor alone from #{role} users" do
        submit(role: role, ages: [ 0, 0 ], enrollment: false)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["clerk_error"]).to be_nil
        expect(response.parsed_body["code"]).to be_in(%w[mfa_required mfa_enrollment_required])
      end
    end
  end
end
