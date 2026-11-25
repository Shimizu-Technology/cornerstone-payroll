# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public employee terms", type: :request do
  let(:digest) { "a" * 64 }
  let(:terms) do
    EmployeeTermsVersion.create!(version: "test-current", status: "approved", terms_url: "/terms",
      privacy_url: "/privacy", published_at: Time.iso8601("2026-11-25T16:00:00Z"), text_digest: digest)
  end

  it "publishes current metadata without authentication" do
    terms
    get "/api/v1/public/employee_terms"

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.parsed_body).to include("version" => terms.version, "title" => "Employee App Terms",
      "effective_date" => "2026-11-26", "text_digest" => digest, "terms_url" => "/terms", "privacy_url" => "/privacy")
  end

  it "reports unavailable when no terms have been published" do
    get "/api/v1/public/employee_terms"
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.fetch("error")).to include("Sign-up is unavailable")

    post "/api/v1/employee/activation", params: {}, as: :json
    expect(response).to have_http_status(:service_unavailable)
  end

  it "rejects stale or missing acceptance before looking up the invite" do
    terms
    expect(EmployeeLinks::Activate).not_to receive(:call)
    [ nil, "test-stale" ].each do |version|
      post "/api/v1/employee/activation", params: { terms_version: version }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "terms_updated")
    end
  end

  it "passes current acceptance through to activation" do
    expect(EmployeeLinks::Activate).to receive(:call).and_return(double(outcome: :unavailable))
    post "/api/v1/employee/activation", params: { terms_version: terms.version }, as: :json
    expect(response.parsed_body).to include("code" => "activation_unavailable")
  end
end
