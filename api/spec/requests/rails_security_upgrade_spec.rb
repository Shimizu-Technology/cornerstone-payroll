# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rails security upgrade request boundaries", type: :request do
  let(:client_ip) { "198.51.100.25" }
  # Puma unmapped the observed Render socket peer to this private IPv4 shape.
  let(:proxy_env) { { "REMOTE_ADDR" => "10.209.25.240" } }

  it "normalizes headers before every other middleware, including request logging" do
    stack = Rails.application.middleware.map(&:klass)

    expect(stack.first).to eq(CanonicalProxyHeaders)
    expect(stack.index(CanonicalProxyHeaders)).to be < stack.index(Rails::Rack::Logger)
    expect(Rails.application.config.action_dispatch.ip_spoofing_check).not_to eq(false)
  end

  {
    "normal traffic" => {},
    "a forged prefix before the trusted edge client in X-Forwarded-For" => {
      "X-Forwarded-For" => "203.0.113.9, 198.51.100.25"
    },
    "matching Forwarded and X-Forwarded-For" => { "Forwarded" => "for=198.51.100.25" },
    "forged Forwarded" => { "Forwarded" => "for=203.0.113.9;proto=https" },
    "forged Client-Ip" => { "Client-Ip" => "203.0.113.9" },
    "matching forged alternative headers" => {
      "Forwarded" => "for=203.0.113.9;proto=https", "Client-Ip" => "203.0.113.9"
    }
  }.each do |label, extra_headers|
    it "uses the canonical client for #{label} in the request, audit context and throttle" do
      expect(Current).to receive(:ip_address=).with(client_ip).and_call_original

      get "/api/v1/auth/me",
          headers: { "X-Forwarded-For" => client_ip }.merge(extra_headers),
          env: proxy_env

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to include("error" => "Not authenticated")
      expect(request.remote_ip).to eq(client_ip)
      expect(Rack::Attack.throttle_ip(Rack::Attack::Request.new(request.env))).to eq(client_ip)
      expect(request.env).not_to have_key("HTTP_FORWARDED")
      expect(request.env).not_to have_key("HTTP_CLIENT_IP")
      expect(request.env.fetch("HTTP_X_FORWARDED_FOR")).to eq(extra_headers.fetch("X-Forwarded-For", client_ip))
    end
  end

  it "logs the canonical client when alternative forwarding headers are forged" do
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(Logger.new(output))
    allow(Rails).to receive(:logger).and_return(logger)

    get "/api/v1/auth/me",
        headers: { "X-Forwarded-For" => client_ip, "Forwarded" => "for=203.0.113.9", "Client-Ip" => "203.0.113.9" },
        env: proxy_env

    expect(response).to have_http_status(:unauthorized)
    expect(output.string).to include('Started GET "/api/v1/auth/me" for ' + client_ip)
    expect(output.string).not_to include("for 203.0.113.9")
  end

  it "keeps unpermitted parameters protected after each_key" do
    values = ActionController::Parameters.new(name: "unreviewed")
    returned = values.each_key { |_key| nil }
    model = Class.new do
      include ActiveModel::Model
      attr_accessor :name
    end

    expect(returned).to equal(values)
    expect(returned).not_to be_permitted
    expect { model.new(returned) }.to raise_error(ActiveModel::ForbiddenAttributesError)
  end
end
