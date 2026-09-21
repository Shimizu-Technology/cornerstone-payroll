# frozen_string_literal: true

require "rails_helper"

RSpec.describe Rack::Attack do
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
end
