# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public file server security headers", type: :request do
  it "emits nosniff and default security headers on /robots.txt" do
    get "/robots.txt"

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    expect(response.headers["X-Frame-Options"]).to eq("DENY")
    expect(response.headers["X-Permitted-Cross-Domain-Policies"]).to eq("none")
    expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
  end

  it "configures the same security headers for production public file serving" do
    production_config = Rails.root.join("config/environments/production.rb").read

    expect(production_config).to include(
      "config.public_file_server.headers = Api::Application::PUBLIC_FILE_SECURITY_HEADERS.merge("
    )
    expect(Api::Application::PUBLIC_FILE_SECURITY_HEADERS).to include(
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY",
      "x-permitted-cross-domain-policies" => "none",
      "referrer-policy" => "no-referrer"
    )
  end
end
