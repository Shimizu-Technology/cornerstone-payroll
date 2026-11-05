# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rails security upgrade request boundaries", type: :request do
  let(:client_ip) { "198.51.100.25" }
  let(:proxy_env) { { "REMOTE_ADDR" => "10.0.0.5" } }

  it "preserves the client address for an X-Forwarded-For-only proxy request" do
    get "/api/v1/auth/me", headers: { "X-Forwarded-For" => client_ip }, env: proxy_env

    expect(response.status).to be < 500
    expect(request.remote_ip).to eq(client_ip)
  end

  it "accepts matching Forwarded and X-Forwarded-For addresses" do
    get "/api/v1/auth/me",
        headers: { "Forwarded" => "for=#{client_ip};proto=https", "X-Forwarded-For" => client_ip },
        env: proxy_env

    expect(response.status).to be < 500
    expect(request.remote_ip).to eq(client_ip)
  end

  it "rejects conflicting forwarding headers before controller work" do
    expect do
      get "/api/v1/auth/me",
          headers: { "Forwarded" => "for=203.0.113.9;proto=https", "X-Forwarded-For" => client_ip },
          env: proxy_env.merge("action_dispatch.show_exceptions" => :none)
    end.to raise_error(ActionDispatch::RemoteIp::IpSpoofAttackError)
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
