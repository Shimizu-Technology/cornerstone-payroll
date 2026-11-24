# frozen_string_literal: true

require "rails_helper"

RSpec.describe Rack::Attack do
  around do |example|
    previously_enabled = described_class.enabled
    described_class.enabled = true
    example.run
  ensure
    described_class.enabled = previously_enabled
  end

  it "dedicates a process-local store to rate limits by default" do
    expect(described_class.cache.store).to equal(RackAttackStore::MEMORY)
    expect(described_class.cache.store).not_to equal(RequestPathCache.store)
    expect(described_class.cache.store).to be_a(ActiveSupport::Cache::MemoryStore)
    expect(described_class.cache.store).not_to equal(Rails.cache)
  end

  it "allows API GET requests when the database-backed cache rejects writes" do
    failing_cache = double("read-only database cache")
    allow(failing_cache).to receive(:method_missing)
      .and_raise(PG::ReadOnlySqlTransaction, "cannot execute INSERT in a read-only transaction")
    allow(Rails).to receive(:cache).and_return(failing_cache)
    app = described_class.new(lambda { |_env| [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ] })

    response = Rack::MockRequest.new(app).get("/api/v1/auth/me", "REMOTE_ADDR" => "203.0.113.15")

    expect(response.status).to eq(200)
    expect(response.body).to eq("ok")
  end

  describe ".throttle_ip" do
    let(:request) do
      instance_double(
        ActionDispatch::Request,
        get_header: remote_addr,
        ip: forwarded_ip
      )
    end
    let(:forwarded_ip) { "198.51.100.25" }

    before do
      allow(Rails.application.config.action_dispatch)
        .to receive(:trusted_proxies)
        .and_return([ IPAddr.new("10.0.0.0/8") ])
    end

    context "when the connection is direct" do
      let(:remote_addr) { "203.0.113.10" }

      it "ignores a spoofable forwarded address" do
        expect(described_class.throttle_ip(request)).to eq(remote_addr)
      end
    end

    context "when the connection comes from a trusted proxy" do
      let(:remote_addr) { "10.0.0.5" }

      it "uses the client address resolved by ActionDispatch::RemoteIp" do
        expect(described_class.throttle_ip(request)).to eq(forwarded_ip)
      end
    end
  end

  describe "AIRE worker statement throttles" do
    let(:app) { described_class.new(lambda { |_env| [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ] }) }
    let(:worker) { "6f1c1d3e-9a4b-4c2d-8e7f-0a1b2c3d4e5f" }

    before { described_class.cache.store.clear }
    after { described_class.cache.store.clear }

    def fetch(path) = Rack::MockRequest.new(app).get(path, "REMOTE_ADDR" => "203.0.113.40")

    it "limits PDF reads per worker without blocking another worker or JSON reads" do
      pdf = "/api/v1/integrations/time_payroll/workers/#{worker}/statements/9/pdf"
      limit = described_class.throttles.fetch("worker_statements/pdf").limit

      statuses = Array.new(limit + 1) { fetch(pdf).status }
      expect(statuses.last).to eq(429)
      expect(statuses.first(limit)).to all(eq(200))
      expect(fetch("/api/v1/integrations/time_payroll/workers/#{worker}/statements/9").status).to eq(200)
      expect(fetch("/api/v1/integrations/time_payroll/workers/#{SecureRandom.uuid}/statements/9/pdf").status).to eq(200)
    end

    it "keys worker reads by worker and ignores other integration paths" do
      throttle = described_class.throttles.fetch("worker_statements/worker")
      request = ->(path) { Rack::Attack::Request.new(Rack::MockRequest.env_for(path, "REMOTE_ADDR" => "203.0.113.40")) }

      expect(throttle.block.call(request.call("/api/v1/integrations/time_payroll/workers/#{worker.upcase}/statements")))
        .to eq("203.0.113.40:#{worker}")
      expect(throttle.block.call(request.call("/api//v1/integrations/time_payroll/workers/#{worker}/%73tatements/9/pdf/")))
        .to eq("203.0.113.40:#{worker}")
      expect(throttle.block.call(request.call("/api/v1/integrations/time_payroll/events"))).to be_nil
    end
  end

  describe "employee and kiosk capacity limits" do
    include ActiveSupport::Testing::TimeHelpers

    let(:app) do
      attack = described_class.new(->(_env) { [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] })
      PayrollTelemetry::Requests.new(attack)
    end
    let(:client) { Rack::MockRequest.new(app) }

    around do |example|
      freeze_time do
        described_class.cache.store.clear
        example.run
      ensure
        described_class.cache.store.clear
      end
    end

    [
      [ "employee/session", :get, "/api/v1/employee/context", 120, 60 ],
      [ "employee/activation_ip", :post, "/api/v1/employee/activate.json", 150, 900 ],
      [ "employee/activation_token", :post, "/api/v1/employee/invitations/activate", 5, 900 ],
      [ "employee/pdf", :get, "/api/v1/employee/pay_stubs/1/pdf", 15, 60 ],
      [ "kiosk/ip", :post, "/api/v1/kiosk/punches", 60, 60 ]
    ].each do |throttle, method, path, limit, period|
      it "enforces #{throttle} and logs and counts each 429" do
        attempts = ->(i) {
          address = throttle == "employee/activation_token" ? "203.0.113.#{i + 1}" : "203.0.113.1"
          token = throttle == "employee/activation_ip" ? "token-#{i}" : "shared-token"
          client.public_send(method, path, "REMOTE_ADDR" => address, "CONTENT_TYPE" => "application/json",
            input: { token: token }.to_json)
        }
        limit.times { |i| expect(attempts.call(i).status).to eq(200) }

        allow(Rails.logger).to receive(:warn).and_call_original
        events = []
        capture = ->(*args) { events << args.last }
        ActiveSupport::Notifications.subscribed(capture, PayrollTelemetry::RATE_LIMIT_METRIC) do
          response = attempts.call(limit)
          expect(response.status).to eq(429)
          expect(response["Retry-After"]).to eq(period.to_s)
        end
        expect(events).to eq([ { throttle: throttle, count: 1 } ])
        expect(Rails.logger).to have_received(:warn).with(a_string_including(
          '"event":"http.rate_limited.payroll"', %("throttle":"#{throttle}"), '"status":429'
        )).once
        expect(client.get("/api/v1/admin/companies", "REMOTE_ADDR" => "203.0.113.1").status).to eq(200)
      end
    end

    it "counts encoded API prefixes against the existing API limit" do
      limit = described_class.throttles.fetch("api/ip").limit
      address = { "REMOTE_ADDR" => "203.0.113.1" }
      limit.times { expect(client.get("/api/v1/admin/companies", address).status).to eq(200) }

      response = client.get("/%61pi//v1/admin/companies/", address)
      expect(response.status).to eq(429)
      expect(response["Retry-After"]).to eq("60")
      expect(client.get("/%61pi", address).status).to eq(429)
      expect(client.get("/%61pis/v1/admin/companies", address).status).to eq(200)
    end

    it "counts encoded auth paths without matching lookalike namespaces" do
      limit = described_class.throttles.fetch("auth/ip").limit
      address = { "REMOTE_ADDR" => "203.0.113.1" }
      limit.times { expect(client.get("/api/v1/auth/me", address).status).to eq(200) }

      expect(client.get("/api//v1/%61uth/me/", address).status).to eq(429)
      expect(client.get("/api//v1/%61uthors", address).status).to eq(200)
    end

    [
      [ :get, "/api/v1/employee/context", "/%61pi//v1/%65mployee/context/", 120 ],
      [ :post, "/api/v1/employee/activate", "/api/v1/employee//%61ctivate/", 5 ],
      [ :get, "/api/v1/employee/pay_stubs/1/pdf", "/api//v1/employee/pay_stubs/1/%70df/", 15 ],
      [ :get, "/api/v1/employee/pay_stubs/1/download", "/api/v1/employee/pay_stubs/2/download", 15 ],
      [ :get, "/api/v1/employee/w2s/2025/download", "/api/v1/employee/w2s/2026/download.pdf", 15 ],
      [ :post, "/api/v1/kiosk/punches", "/api//v1/%6Biosk/punches/", 60 ]
    ].each do |method, canonical, equivalent, limit|
      it "shares the limit for #{canonical} with #{equivalent}" do
        options = { "REMOTE_ADDR" => "203.0.113.1", "CONTENT_TYPE" => "application/json", input: { token: "same-token" }.to_json }
        limit.times { expect(client.public_send(method, canonical, **options).status).to eq(200) }
        expect(client.public_send(method, equivalent, **options).status).to eq(429)
      end
    end

    [
      [ "application/x-www-form-urlencoded", "token=private-token", nil, 415 ],
      [ "application/json", { token: "private-token", padding: " " * 4096 }.to_json, nil, 413 ],
      [ "application/json", { token: "private-token", padding: " " * 4096 }.to_json, "1", 413 ],
      [ "application/json", { unrelated: "private-token" }.to_json, nil, 400 ]
    ].each do |content_type, payload, claimed_length, status|
      it "rejects invalid activation payloads before dispatch (#{status}, claimed length #{claimed_length.inspect})" do
        downstream = ->(_env) { raise "invalid activation reached the app" }
        env = Rack::MockRequest.env_for("/api//v1/employee/%61ctivate", method: :post, input: payload,
          "REMOTE_ADDR" => "203.0.113.1", "CONTENT_TYPE" => content_type)
        env["CONTENT_LENGTH"] = claimed_length
        actual, headers, body = described_class.new(downstream).call(env)
        expect(actual).to eq(status)
        expect(headers).to include("content-type" => "application/json", "cache-control" => "no-store")
        expect(JSON.parse(body.join)).to eq("error" => "Invalid activation request")
      end
    end

    it "leaves payroll, AIRE events, and lookalike paths outside the new limits" do
      paths = %w[
        /api/v1/admin/employees/1/pay_stubs/2/pdf /api/v1/client/pay_stubs/2/download
        /api/v1/integrations/aire/events /api//v1/%65mployee_directory /api/v1/%6Biosk_status
        /api/v1/form_500s/download /api/v1/finance/context
      ]
      paths.each_with_index do |path, i|
        121.times { expect(client.get(path, "REMOTE_ADDR" => "203.0.113.#{i + 1}").status).to eq(200) }
      end
    end

    it "accepts a printed code in place of a token and limits each code across addresses" do
      post = ->(path, body, i) {
        client.post(path, "REMOTE_ADDR" => "203.0.113.#{i + 1}", "CONTENT_TYPE" => "application/json", input: body.to_json)
      }
      5.times { |i| expect(post.call("/api/v1/employee/activation", { code: "ACDEF-GHJKM" }, i).status).to eq(200) }
      # The same code, typed differently, on the claim route shares the limit.
      expect(post.call("/api/v1/employee/links/claim", { code: "acdefghjkm" }, 9).status).to eq(429)
      # A token with the same text is a different secret.
      expect(post.call("/api/v1/employee/activation", { token: "ACDEFGHJKM" }, 10).status).to eq(200)
      expect(post.call("/api/v1/employee/links/claim", { code: "", token: "" }, 11).status).to eq(400)
    end

    it "keys the limit on the credential the check verifies: an overlong or blank token falls back to the code" do
      post = ->(body, i) {
        client.post("/api/v1/employee/activation", "REMOTE_ADDR" => "203.0.113.#{i + 1}",
          "CONTENT_TYPE" => "application/json", input: body.to_json)
      }
      key = ->(body) {
        env = Rack::MockRequest.env_for("/api/v1/employee/activation", method: :post, input: body.to_json,
          "CONTENT_TYPE" => "application/json")
        request = Rack::Attack::Request.new(env)
        described_class.activation_payload_status(request)
        request.env["payroll.activation_token_digest"]
      }
      code_only = key.call(code: "ACDEFGHJKM")
      expect(key.call(code: "ACDEFGHJKM", token: "t" * 257)).to eq(code_only)
      expect(key.call(code: "ACDEFGHJKM", token: "   ")).to eq(code_only)
      expect(code_only).to eq(EmployeeLinks::Credentials.select(token: nil, code: "acdef-ghjkm").throttle_key)

      5.times { |i| expect(post.call({ code: "ACDEFGHJKM", token: "x#{i}" * 200 }, i).status).to eq(200) }
      expect(post.call({ code: "ACDEFGHJKM" }, 9).status).to eq(429)
      # An overlong token with no usable code names no credential at all.
      expect(post.call({ token: "t" * 257 }, 10).status).to eq(400)
      expect(post.call({ code: "TOO-SHORT" }, 11).status).to eq(400)
    end

    it "refuses a check field in the query string so no layer reads a different credential" do
      downstream = ->(_env) { raise "a conflicting credential reached the app" }
      %w[token=other code=ACDEFGHJKM date_of_birth=1990-01-01 ssn_last4=1234].each do |query|
        env = Rack::MockRequest.env_for("/api/v1/employee/activation?#{query}", method: :post,
          input: { token: "body-token" }.to_json, "REMOTE_ADDR" => "203.0.113.1", "CONTENT_TYPE" => "application/json")
        status, _headers, body = described_class.new(downstream).call(env)
        expect([ status, JSON.parse(body.join) ]).to eq([ 400, { "error" => "Invalid activation request" } ])
      end
    end

    it "leaves the activation body intact for downstream handlers" do
      downstream = ->(env) { [ 200, { "content-type" => "application/json" }, [ env["rack.input"].read ] ] }
      payload = { token: "secret-activation-token" }.to_json
      response = Rack::MockRequest.new(described_class.new(downstream)).post("/api/v1/employee/activate",
        "REMOTE_ADDR" => "203.0.113.1", "CONTENT_TYPE" => "application/json", input: payload)
      expect(response.body).to eq(payload)
    end
  end

  describe "one restaurant's shared Wi-Fi" do
    include ActiveSupport::Testing::TimeHelpers

    let(:app) do
      PayrollTelemetry::Requests.new(described_class.new(->(_env) { [ 200, { "content-type" => "application/json" }, [ "{}" ] ] }))
    end
    let(:client) { Rack::MockRequest.new(app) }
    let(:wifi) { "203.0.113.77" }
    let(:origin) { "https://wifidiner.shimizu-technology.com" }
    let!(:company) do
      create(:company, subdomain_slug: "wifidiner").tap do |company|
        company.client_operating_profiles.create!(effective_on: PayrollBusinessClock.today, version: 1,
          offering: "payroll_service", hours_source: "manual", options: { subdomain_enabled: true })
        TenantSubdomainRegistry.invalidate!
      end
    end

    around do |example|
      freeze_time do
        described_class.cache.store.clear
        example.run
      ensure
        described_class.cache.store.clear
      end
    end

    let(:issuer) { "https://clerk.wifi.example.test" }
    let(:signing_key) { OpenSSL::PKey::RSA.generate(2048) }
    let(:jwk) { JWT::JWK.new(signing_key) }

    # Session limits key only on tokens that verify; this verifier trusts a
    # local key, as ClerkTokenVerifier does Clerk's JWKS.
    before do
      verifier = ClerkTokenVerifier.new(
        env: { "CLERK_ISSUER" => issuer, "CLERK_AUTHORIZED_PARTIES" => "https://payroll.example.test" },
        cache: ActiveSupport::Cache::MemoryStore.new,
        http_get: ->(_uri) { [ 200, { "keys" => [ jwk.export.deep_stringify_keys ] } ] }
      )
      allow(ClerkTokenVerifier).to receive(:new).and_return(verifier)
    end

    def bearer(session, azp: origin, key: signing_key)
      claims = { sid: session, sub: "user_x", iss: issuer, azp: azp, iat: Time.current.to_i, exp: 5.minutes.from_now.to_i }
      "Bearer #{JWT.encode(claims, key, 'RS256', kid: jwk.kid)}"
    end

    # Same shape and kid, but signed with another key.
    def forged_bearer(session)
      bearer(session, key: OpenSSL::PKey::RSA.generate(2048))
    end

    # The tenant site preflights every call (max_age 0), without a session.
    def phone(method, path, session: nil, body: nil, authorization: nil, from: origin)
      preflight = client.options(path, "REMOTE_ADDR" => wifi, "HTTP_ORIGIN" => from,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => method.to_s.upcase)
      return preflight if preflight.status == 429

      headers = { "REMOTE_ADDR" => wifi, "HTTP_ORIGIN" => from }
      headers["HTTP_AUTHORIZATION"] = authorization || bearer(session) if authorization || session
      if body
        headers["CONTENT_TYPE"] = "application/json"
        headers[:input] = body.to_json
      end
      client.public_send(method, path, headers)
    end

    it "lets 30 phones sign up, load /auth/me, browse and download stubs together" do
      statuses = Array.new(30) do |i|
        session = "sess_phone#{i}"
        [
          *Array.new(2) { phone(:post, "/api/v1/employee/activation", body: { token: "invite-#{i}" }) },
          *Array.new(3) { phone(:get, "/api/v1/auth/me", session: session) },
          *Array.new(15) { phone(:get, "/api/v1/employee/context", session: session) },
          *Array.new(5) { phone(:get, "/api/v1/employee/pay_stubs/#{i}/pdf", session: session) }
        ].map(&:status)
      end

      expect(statuses.flatten.tally).to eq(200 => 30 * 25)
    end

    it "still limits each phone on its own, with a readable CORS answer for the tenant site" do
      20.times { expect(phone(:get, "/api/v1/auth/me", session: "sess_busy").status).to eq(200) }

      throttled = phone(:get, "/api/v1/auth/me", session: "sess_busy")
      expect(throttled.status).to eq(429)
      expect(throttled.headers).to include("access-control-allow-origin" => origin, "access-control-allow-credentials" => "true")
      expect(phone(:get, "/api/v1/auth/me", session: "sess_other").status).to eq(200)

      15.times { phone(:get, "/api/v1/employee/pay_stubs/1/pdf", session: "sess_busy") }
      expect(phone(:get, "/api/v1/employee/pay_stubs/1/pdf", session: "sess_busy").status).to eq(429)
    end

    it "keeps a per-IP backstop when every request is a new session" do
      1500.times { |i| phone(:get, "/api/v1/employee/context", session: "sess_many#{i}") }
      expect(phone(:get, "/api/v1/employee/context", session: "sess_fresh").status).to eq(429)
    end

    it "keys nothing on an unverified session: forged tokens share the per-IP limits and can't drain a real session" do
      20.times { |i| phone(:get, "/api/v1/auth/me", authorization: forged_bearer("sess_forged#{i}")) }
      expect(phone(:get, "/api/v1/auth/me", authorization: forged_bearer("sess_one_more")).status).to eq(429)

      # Forging the victim's sid doesn't spend the victim's bucket.
      described_class.cache.store.clear
      19.times { phone(:get, "/api/v1/auth/me", authorization: forged_bearer("sess_victim")) }
      expect(phone(:get, "/api/v1/auth/me", session: "sess_victim").status).to eq(200)

      described_class.cache.store.clear
      120.times { |i| phone(:get, "/api/v1/employee/context", authorization: forged_bearer("sess_forged#{i}")) }
      expect(phone(:get, "/api/v1/employee/context", authorization: forged_bearer("sess_next")).status).to eq(429)
      expect(phone(:get, "/api/v1/employee/context", session: "sess_real").status).to eq(200)
    end

    it "gives the tenant exemption only to a registered client origin on /auth/me" do
      unregistered = "https://unknown.shimizu-technology.com"
      20.times { |i| phone(:get, "/api/v1/auth/me", session: "sess_u#{i}", from: unregistered) }
      expect(phone(:get, "/api/v1/auth/me", session: "sess_u_next", from: unregistered).status).to eq(429)

      described_class.cache.store.clear
      20.times { |i| client.post("/api/v1/invitations/accept", "REMOTE_ADDR" => wifi, "HTTP_ORIGIN" => origin,
        "HTTP_AUTHORIZATION" => bearer("sess_inv#{i}")) }
      expect(client.post("/api/v1/invitations/accept", "REMOTE_ADDR" => wifi, "HTTP_ORIGIN" => origin,
        "HTTP_AUTHORIZATION" => bearer("sess_inv_next")).status).to eq(429)
    end

    it "keeps strict per-invite limits and adds tenant CORS to a rejected sign-up body" do
      5.times { phone(:post, "/api/v1/employee/activation", body: { code: "ACDEF-GHJKM" }) }
      expect(phone(:post, "/api/v1/employee/activation", body: { code: "ACDEFGHJKM" }).status).to eq(429)

      rejected = phone(:post, "/api/v1/employee/activation", body: { email: "someone@example.net" })
      expect(rejected.status).to eq(400)
      expect(rejected.headers["access-control-allow-origin"]).to eq(origin)

      unknown = client.post("/api/v1/employee/activation", "REMOTE_ADDR" => wifi, "CONTENT_TYPE" => "application/json",
        "HTTP_ORIGIN" => "https://unknown.shimizu-technology.com", input: "{}")
      expect(unknown.headers).not_to include("access-control-allow-origin")
    end

    it "leaves staff on the main origin with the per-IP auth limit" do
      20.times { |i| client.get("/api/v1/auth/me", "REMOTE_ADDR" => wifi, "HTTP_AUTHORIZATION" => bearer("sess_staff#{i}")) }
      expect(client.get("/api/v1/auth/me", "REMOTE_ADDR" => wifi, "HTTP_AUTHORIZATION" => bearer("sess_new")).status).to eq(429)
    end
  end
end
