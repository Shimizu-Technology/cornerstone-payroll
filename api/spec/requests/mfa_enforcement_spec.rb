# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Clerk MFA enforcement", type: :request do
  let(:user) { create(:user, role: role, clerk_id: "user_mfa_spec") }
  let(:role) { :admin }
  let(:issuer) { "https://payroll-mfa.clerk.accounts.dev" }
  let(:origin) { "https://payroll.example.test" }
  let(:signing_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk) { JWT::JWK.new(signing_key) }
  let(:verifier) do
    ClerkTokenVerifier.new(
      env: { "CLERK_ISSUER" => issuer, "CLERK_AUTHORIZED_PARTIES" => origin },
      cache: ActiveSupport::Cache::MemoryStore.new,
      http_get: jwks_fetch
    )
  end
  let(:jwks_fetch) { spy("synthetic JWKS fetch", call: [ 200, { "keys" => [ jwk.export.deep_stringify_keys ] } ]) }
  let(:denials) { AuditLog.where(action: "authentication#mfa_required_denied") }

  around do |example|
    previous = ENV["REQUIRE_MFA"]
    ENV["REQUIRE_MFA"] = "true"
    example.run
  ensure
    ENV["REQUIRE_MFA"] = previous
  end

  before do
    synthetic_verifier = verifier
    allow(ClerkTokenVerifier).to receive(:new).and_return(synthetic_verifier)
    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(false)
    expect(ClerkInvitationService).not_to receive(:new)
  end

  def headers(fva: :missing)
    claims = { sub: user.clerk_id, iss: issuer, azp: origin, exp: 5.minutes.from_now.to_i, sid: "sess_synthetic" }
    claims[:fva] = fva unless fva == :missing
    token = JWT.encode(claims, signing_key, "RS256", kid: jwk.kid)
    {
      "Authorization" => "Bearer #{token}", "X-Company-Id" => user.company_id.to_s,
      "REMOTE_ADDR" => "192.0.2.24", "User-Agent" => "MFA request spec"
    }
  end

  [
    [ :get, "/api/v1/companies", :admin, :ok ],
    [ :get, "/api/v1/admin/employees", :accountant, :ok ],
    [ :get, "/api/v1/admin/finance_books", :admin, :ok ],
    [ :get, "/api/v1/client/employees", :client, :ok ],
    [ :get, "/api/v1/form_500s/defaults", :admin, :unprocessable_content ],
    [ :get, "/api/v1/notification_settings", :client, :ok ],
    [ :post, "/api/v1/cable_ticket", :admin, :created ]
  ].each do |verb, path, caller_role, normal_status|
    context "#{verb.upcase} #{path} as #{caller_role}" do
      let(:role) { caller_role }

      it "denies an unverified session before normal endpoint processing" do
        expect { public_send(verb, path, headers: headers(fva: [ 5, -1 ])) }.to change(denials, :count).by(1)
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to eq("code" => "mfa_required", "error" => MfaPolicy::ERROR_MESSAGE)
        expect(denials.last).to have_attributes(
          user_id: user.id, record_id: user.id, event_category: "security", metadata: { "source" => "clerk_session" },
          subject_name: user.name, ip_address: "192.0.2.24", user_agent: "MFA request spec"
        )
        expect(AuditLogPresenter.new(denials.last).headline)
          .to eq("#{user.name} was denied payroll access because multi-factor authentication was required")
        expect(CableConnectionTicket.count).to eq(0) if verb == :post
      end

      it "preserves the same outcome with MFA verified or the switch off and uses the same JWKS" do
        public_send(verb, path, headers: headers(fva: [ 5, 2 ]))
        expect(response).to have_http_status(normal_status)
        verified_body = response.parsed_body

        ENV["REQUIRE_MFA"] = "false"
        expect(MfaPolicy).not_to receive(:verified_second_factor?)
        expect { public_send(verb, path, headers: headers) }.not_to change(denials, :count)
        expect(response).to have_http_status(normal_status)
        if verb == :post
          expect(response.parsed_body.fetch("ticket")).to match(/\A[A-Za-z0-9_-]{43}\z/)
          expect(response.parsed_body.fetch("expires_in")).to eq(verified_body.fetch("expires_in"))
        else
          expect(response.parsed_body).to eq(verified_body)
        end
        expect(jwks_fetch).to have_received(:call).once
      end
    end
  end

  [ :missing, nil, [ 5, nil ], [ 5 ], [ 5, "0" ], [ 5, 0.5 ], [ -2, 0 ], [ "5", 0 ], "5,0" ].each do |claim|
    it "denies fva=#{claim.inspect} in a valid signed token" do
      get "/api/v1/companies", headers: headers(fva: claim)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("code")).to eq("mfa_required")
    end
  end

  it "returns only recovery status from auth/me until a second factor has been verified" do
    expect do
      get "/api/v1/auth/me", headers: headers(fva: [ 5, -1 ])
    end.to change(denials, :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("mfa_required" => true, "mfa_verified" => false)

    get "/api/v1/auth/me", headers: headers(fva: [ 5, 0 ])
    verified_body = response.parsed_body
    expect(verified_body).to include("mfa_required" => true, "mfa_verified" => true)
    expect(verified_body.dig("user", "id")).to eq(user.id)

    ENV.delete("REQUIRE_MFA")
    expect { get "/api/v1/auth/me", headers: headers }.not_to change(denials, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(verified_body.except("mfa_required", "mfa_verified"))
    expect(jwks_fetch).to have_received(:call).once
  end

  it "mirrors GET for HEAD auth/me, with the expected empty response body" do
    [ [ 5, -1 ], [ 5, 0 ] ].each do |ages|
      get "/api/v1/auth/me", headers: headers(fva: ages)
      get_status = response.status

      head "/api/v1/auth/me", headers: headers(fva: ages)
      expect(response).to have_http_status(get_status)
      expect(response).to have_http_status(:ok)
      expect(response.body).to be_empty
    end
  end

  it "accepts a previously verified second factor for global access even beyond the step-up window" do
    get "/api/v1/companies", headers: headers(fva: [ 5, 15 ])

    expect(response).to have_http_status(:ok)
  end

  it "preserves unauthorized for an invalid token when MFA is on" do
    get "/api/v1/auth/me", headers: { "Authorization" => "Bearer invalid.token" }

    expect(response).to have_http_status(:unauthorized)
    expect(denials).to be_empty
  end

  describe "/api/v1/employee/context" do
    let(:employee) { create(:employee, company: user.company) }
    let(:link) { EmployeeAccountLink.create!(user: user, company: user.company, employee: employee, status: :active) }

    def employee_context(fva:)
      get "/api/v1/employee/context", headers: headers(fva: fva).merge("X-Employee-Link-Id" => link.id.to_s)
    end

    it "denies MFA before looking up the employee link or opening company scope" do
      link
      expect(TenantScope).not_to receive(:with_company)
      allow(TenantScope).to receive(:as_system).and_call_original
      expect(TenantScope).not_to receive(:as_system).with(reason: "Resolve employee link for verified Clerk user")

      employee_context(fva: [ 5, -1 ])
      expect(response).to have_http_status(:forbidden)
      expect(denials.count).to eq(1)
    end

    [ :admin, :client, :portal_employee ].each do |caller_role|
      context "as #{caller_role} with an active employee link" do
        let(:role) { caller_role }

        it "applies global MFA by role before the company feature and preserves existing behavior when off" do
          employee_context(fva: [ 5, -1 ])
          if caller_role == :portal_employee
            expect(response).to have_http_status(:not_found)
            expect(denials).to be_empty
          else
            expect(response).to have_http_status(:forbidden)
            expect(response.parsed_body.fetch("code")).to eq("mfa_required")
            expect(denials.last).to have_attributes(
              user_id: user.id, subject_name: user.name, ip_address: "192.0.2.24", user_agent: "MFA request spec"
            )
          end

          allow_any_instance_of(CompanyFeatures).to receive(:employee_portal_enabled?).and_return(true)
          employee_context(fva: caller_role == :portal_employee ? [ 5, -1 ] : [ 5, 1 ])
          expect(response).to have_http_status(:no_content)

          ENV["REQUIRE_MFA"] = "false"
          expect { employee_context(fva: [ 5, -1 ]) }.not_to change(denials, :count)
          expect(response).to have_http_status(:no_content)
          expect(jwks_fetch).to have_received(:call).once
        end
      end
    end
  end
end
