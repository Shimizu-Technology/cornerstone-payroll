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
      [ "employee/ip", :get, "/api/v1/employee/context", 120, 60 ],
      [ "employee/activation_ip", :post, "/api/v1/employee/activate.json", 10, 900 ],
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

    it "leaves the activation body intact for downstream handlers" do
      downstream = ->(env) { [ 200, { "content-type" => "application/json" }, [ env["rack.input"].read ] ] }
      payload = { token: "secret-activation-token" }.to_json
      response = Rack::MockRequest.new(described_class.new(downstream)).post("/api/v1/employee/activate",
        "REMOTE_ADDR" => "203.0.113.1", "CONTENT_TYPE" => "application/json", input: payload)
      expect(response.body).to eq(payload)
    end
  end
end
