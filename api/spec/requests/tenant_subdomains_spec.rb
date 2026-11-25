# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client subdomains", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:path) { "/api/v1/public/tenant_branding" }
  let(:enabled_host) { "mosas.shimizu-technology.com" }
  let(:disabled_host) { "disabled.shimizu-technology.com" }
  let(:payroll_origin) { "https://payroll.shimizu-technology.com" }
  let(:issuer) { "https://clerk.shimizu-technology.com" }
  let(:enabled) do
    create(:company, subdomain_slug: "mosas", name: "Example Employer", ein: "12-3456789", branding: {
      logo_url: "https://example.test/mark.png", primary_color: "#214F44", accent_color: "#FAD625"
    })
  end
  let(:disabled) { create(:company, subdomain_slug: "disabled") }
  let!(:enabled_profile) { create_profile(enabled, true) }
  let!(:disabled_profile) { create_profile(disabled, false) }

  def create_profile(company, enabled)
    company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service",
      hours_source: "manual", options: { subdomain_enabled: enabled }
    )
  end

  def preflight(origin, request_path: path, method: "GET")
    options request_path, headers: { "Origin" => origin, "Access-Control-Request-Method" => method }
    response.headers["Access-Control-Allow-Origin"]
  end

  def malformed_client_origins
    [
      "https://#{enabled_host}.", "https://#{enabled_host.upcase}",
      "https://mоsas.shimizu-technology.com", "https://#{enabled_host}:8443",
      "https://#{enabled_host}:443", "https://#{enabled_host}/"
    ]
  end

  def malformed_origins
    [ "null", "https://www.shimizu-technology.com", *malformed_client_origins ]
  end

  it "allows only the exact HTTPS enabled client origin in CORS preflights" do
    origin = "https://#{enabled_host}"
    expect(preflight(origin)).to eq(origin)
    expect(response.headers["Access-Control-Allow-Credentials"]).to be_nil
    expect(response.headers["Access-Control-Allow-Methods"].split(", ")).to match_array(%w[GET HEAD OPTIONS])
    expect(preflight(origin, method: "POST")).to be_nil

    [
      "https://#{disabled_host}",
      "https://unknown.shimizu-technology.com",
      "https://evil-shimizu-technology.com",
      "https://#{enabled_host}.evil.com",
      "https://nested.#{enabled_host}",
      "http://#{enabled_host}",
      "https://#{enabled_host}:444",
      "https://*.shimizu-technology.com",
      *malformed_origins
    ].each do |refused|
      expect(preflight(refused)).to be_nil, "unexpected CORS approval for #{refused}"
    end
  end

  it "serves only the public branding fields for either lookup form without authentication" do
    # The public response also filters legacy rows written outside validations.
    enabled.update_columns(branding: enabled.branding.merge("contact_email" => "internal@example.test", "company_id" => 123))

    [ { host: enabled_host }, { slug: "mosas" } ].each do |lookup|
      get path, params: lookup, headers: { "Origin" => "https://#{enabled_host}" }
      expect(response).to have_http_status(:ok)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("https://#{enabled_host}")
      expect(response.headers["Access-Control-Allow-Credentials"]).to be_nil
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.parsed_body).to eq(
        "name" => "Example Employer", "app_name" => nil, "logo_url" => "https://example.test/mark.png",
        "primary_color" => "#214F44", "accent_color" => "#FAD625", "main_phone" => "6715551234"
      )
    end
  end

  it "returns the same empty 404 for disabled, unknown, reserved and malformed lookups" do
    [
      { host: disabled_host }, { slug: "disabled" }, { host: "unknown.shimizu-technology.com" },
      { host: "payroll.shimizu-technology.com" }, { host: "#{enabled_host}.evil.com" },
      { host: "https://#{enabled_host}" }, { host: [ enabled_host ] }, { slug: { name: "mosas" } },
      { host: enabled_host, slug: "mosas" }, {}
    ].each do |lookup|
      get path, params: lookup
      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  it "drops unusable logo and color values from the public payload" do
    enabled.update_columns(branding: {
      logo_url: "https://public.example.test/mark.png?X-Amz-Signature=test", primary_color: {}, accent_color: "red",
      display_name: "<b>Example</b>", app_name: "x" * 31
    })

    get path, params: { host: enabled_host }

    expect(response.parsed_body).to eq(
      "name" => "Example Employer", "app_name" => nil, "logo_url" => nil, "primary_color" => nil, "accent_color" => nil,
      "main_phone" => "6715551234"
    )
  end

  it "uses the effective profile and sees slug, flag and active-status changes on the next request" do
    expect(preflight("https://#{enabled_host}")).to eq("https://#{enabled_host}")

    enabled_profile.update!(options: { subdomain_enabled: false })
    enabled.update!(subdomain_slug: "renamed")
    expect(preflight("https://#{enabled_host}")).to be_nil
    expect(preflight("https://renamed.shimizu-technology.com")).to be_nil
    get path, params: { slug: "renamed" }
    expect(response).to have_http_status(:not_found)

    tomorrow = PayrollBusinessClock.today + 1.day
    enabled_profile.update!(ends_on: PayrollBusinessClock.today)
    enabled.client_operating_profiles.create!(
      effective_on: tomorrow, version: 2, offering: "payroll_service",
      hours_source: "manual", options: { subdomain_enabled: true }
    )
    expect(preflight("https://renamed.shimizu-technology.com")).to be_nil

    travel 1.day do
      expect(preflight("https://renamed.shimizu-technology.com")).to eq("https://renamed.shimizu-technology.com")
      enabled.update!(active: false)
      expect(preflight("https://renamed.shimizu-technology.com")).to be_nil
    end
  end

  it "scopes credentialed tenant CORS to auth and employee paths" do
    origin = "https://#{enabled_host}"
    %w[/api/v1/auth/me /api/v1/employee/context].each do |request_path|
      expect(preflight(origin, request_path: request_path)).to eq(origin)
      expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
    end

    %w[/api/v1/admin/employees /api/v1/client/employees].each do |request_path|
      expect(preflight(origin, request_path: request_path)).to be_nil
      get request_path, headers: { "Origin" => origin }
      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end
  end

  it "excludes an inactive organization from CORS and branding" do
    origin = "https://#{enabled_host}"
    expect(preflight(origin)).to eq(origin)

    enabled.organization.update!(status: "inactive")

    expect(preflight(origin)).to be_nil
    get path, params: { host: enabled_host }, headers: { "Origin" => origin }
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
  end

  def sql_during
    queries = []
    listener = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { yield }
    queries
  end

  it "loads the registry in one query and serves later origin checks with no queries" do
    origin = "https://#{enabled_host}"
    create(:company, subdomain_slug: "without-profile")
    first = sql_during { expect(preflight(origin)).to eq(origin) }
    expect(first.grep(/SELECT.*"(?:client_operating_profiles|companies)"/i).size).to eq(1)

    expect(sql_during {
      expect(preflight(origin)).to eq(origin)
      expect(preflight("https://without-profile.shimizu-technology.com")).to be_nil
    }).to be_empty

    enabled_profile.update!(options: { subdomain_enabled: false })
    expect(preflight(origin)).to be_nil
    expect(TenantSubdomainRegistry.allowed_origin?(nil)).to be(false)
  end

  it "keeps /up DB-free for both enabled and disabled origins even with a cold cache" do
    [ enabled_host, disabled_host ].each do |host|
      expect(sql_during {
        get "/up", headers: { "Origin" => "https://#{host}" }
        expect(response).to have_http_status(:ok)
        expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
      }).to be_empty
    end
  end

  it "shares the per-IP limit across branding GETs, double slashes and client preflights" do
    previously_enabled = Rack::Attack.enabled
    Rack::Attack.enabled = true
    limit = Rack::Attack.throttles.fetch("tenant_branding/ip").limit
    enabled_origin = "https://#{enabled_host}"
    disabled_origin = "https://#{disabled_host}"
    address = { "REMOTE_ADDR" => "203.0.113.61" }
    double_slash_path = "/api//v1/public/tenant_branding"

    freeze_time do
      options path, headers: { "Origin" => enabled_origin, "Access-Control-Request-Method" => "GET" }, env: address
      expect(response.headers["Access-Control-Allow-Origin"]).to eq(enabled_origin)

      (limit - 1).times do |index|
        get double_slash_path, params: { slug: "missing-#{index}" }, env: address
        expect(response).to have_http_status(:not_found)
      end

      # A throttled answer stays readable on the enabled tenant site (M4-2),
      # without credentials on the public branding path; others get no CORS.
      [ [ enabled_origin, enabled_origin ], [ disabled_origin, nil ] ].each do |origin, allowed|
        get double_slash_path, params: { slug: "mosas" }, headers: { "Origin" => origin }, env: address
        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Access-Control-Allow-Origin"]).to eq(allowed)
        expect(response.headers["Access-Control-Allow-Credentials"]).to be_nil
        expect(response.headers["Retry-After"]).to eq("60")

        options path, headers: { "Origin" => origin, "Access-Control-Request-Method" => "GET" }, env: address
        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Access-Control-Allow-Origin"]).to eq(allowed)

        # Employee and auth preflights from one shared Wi-Fi have their own,
        # much higher per-IP backstop instead of the branding limit.
        [ "/api/v1/auth/me", "/api/v1/employee/context" ].each do |request_path|
          options request_path, headers: { "Origin" => origin, "Access-Control-Request-Method" => "GET" }, env: address
          expect(response).not_to have_http_status(:too_many_requests)
        end
      end

      stub_const("PayrollCors::STATIC_ORIGINS", [ payroll_origin ])
      get path, params: { slug: "mosas" }, headers: { "Origin" => payroll_origin }, env: address
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq(payroll_origin)
      expect(response.headers["Access-Control-Expose-Headers"]).to include("Retry-After")

      get double_slash_path, params: { slug: "mosas" }, env: { "REMOTE_ADDR" => "203.0.113.62" }
      expect(response).to have_http_status(:ok)
    end
  ensure
    Rack::Attack.enabled = previously_enabled
  end

  describe "signed Clerk tokens" do
    let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
    let(:jwk) { JWT::JWK.new(rsa_key) }
    let(:user) { create(:user, company: enabled, clerk_id: "user_subdomains") }
    let(:verifier_env) do
      {
        "CLERK_ISSUER" => issuer,
        # A static entry cannot override the profile switch or HTTPS rule.
        "CLERK_AUTHORIZED_PARTIES" => [ payroll_origin, "https://#{disabled_host}", "http://#{enabled_host}" ].join(",")
      }
    end
    let(:verifier) do
      ClerkTokenVerifier.new(env: verifier_env, cache: ActiveSupport::Cache::MemoryStore.new,
        http_get: ->(_uri) { [ 200, { "keys" => [ jwk.export.deep_stringify_keys ] } ] })
    end

    def token_for(origin)
      JWT.encode({ sub: user.clerk_id, iss: issuer, azp: origin, exp: 5.minutes.from_now.to_i }, rsa_key, "RS256", { kid: jwk.kid })
    end

    it "accepts the enabled client origin and rejects disabled, unknown, look-alike and HTTP origins" do
      expect(verifier.verify(token_for("https://#{enabled_host}"))).to include("azp" => "https://#{enabled_host}")
      [
        "https://#{disabled_host}", "https://unknown.shimizu-technology.com", "https://evil-shimizu-technology.com",
        "https://#{enabled_host}.evil.com", "http://#{enabled_host}", "https://#{enabled_host}:444",
        *malformed_origins
      ].each do |origin|
        expect(verifier.verify(token_for(origin))).to be_nil, "unexpected Clerk approval for #{origin}"
      end

      enabled_profile.update!(options: { subdomain_enabled: false })
      expect(verifier.verify(token_for("https://#{enabled_host}"))).to be_nil
    end

    it "rejects a previously enabled origin when the organization becomes inactive" do
      token = token_for("https://#{enabled_host}")
      expect(verifier.verify(token)).to be_present
      enabled.organization.update!(status: "inactive")
      expect(verifier.verify(token)).to be_nil
    end

    it "rejects tenant origins when the static Clerk allowlist is unset and logs why" do
      verifier_env.delete("CLERK_AUTHORIZED_PARTIES")
      expect(Rails.logger).to receive(:warn).with(/client subdomain requires CLERK_AUTHORIZED_PARTIES/).at_least(:once)
      [ "https://#{enabled_host}", *malformed_client_origins ].each do |origin|
        expect(verifier.verify(token_for(origin))).to be_nil
      end
      expect(verifier.verify(token_for(payroll_origin))).to be_present
    end

    it "rejects a tenant token on admin and client endpoints before account binding" do
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(false)
      allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
      token = token_for("https://#{enabled_host}")

      %w[/api/v1/admin/employees /api/v1/client/employees /api/v1/admin/client_inbox/counts].each do |request_path|
        get request_path, headers: { "Authorization" => "Bearer #{token}" }
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body["error"]).to eq("This sign-in is limited to the employee portal")
      end
    end

    it "only lets a tenant token open an employee link for that tenant" do
      allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
      enabled_profile.update!(employee_portal_enabled: true)
      disabled_profile.update!(employee_portal_enabled: true)
      [ enabled, disabled ].each { |company| activate_employee_app!(company) }
      company_links = [ enabled, disabled ].map do |company|
        EmployeeAccountLink.create!(user: user, company: company, employee: create(:employee, company: company), status: :active)
      end
      token = token_for("https://#{enabled_host}")

      company_links.zip([ :ok, :not_found ]).each do |link, status|
        get "/api/v1/employee/context", headers: {
          "Authorization" => "Bearer #{token}", "X-Employee-Link-Id" => link.id.to_s
        }
        expect(response).to have_http_status(status)
      end
    end

    it "accepts an enabled tenant token on the auth entry point" do
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(false)
      allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
      origin = "https://#{enabled_host}"

      get "/api/v1/auth/me", headers: { "Origin" => origin, "Authorization" => "Bearer #{token_for(origin)}" }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Access-Control-Allow-Origin"]).to eq(origin)
    end

    it "continues to authenticate staff on the configured Payroll origin" do
      allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(false)
      allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
      token = token_for(payroll_origin)

      get "/api/v1/auth/me", headers: { "Origin" => payroll_origin, "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("user", "id")).to eq(user.id)
    end
  end
end
