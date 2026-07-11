# frozen_string_literal: true

require "rails_helper"

RSpec.describe Rack::Attack do
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
