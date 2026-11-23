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

  it "uses a process-local store instead of the database-backed Rails cache" do
    expect(described_class.cache.store).to equal(RequestPathCache.store)
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

    it "leaves payroll, AIRE events, and lookalike paths outside the new limits" do
      paths = %w[
        /api/v1/admin/employees/1/pay_stubs/2/pdf /api/v1/client/pay_stubs/2/download
        /api/v1/integrations/aire/events /api/v1/employee_directory /api/v1/kiosk_status
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
