# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dependency health", type: :request do
  it "returns 200 without authentication when dependencies are ready" do
    report = instance_double(DependencyHealth::Report, ready?: true, as_json: { status: "ok" })
    allow(DependencyHealth).to receive(:new).and_return(instance_double(DependencyHealth, run: report))

    get "/health/dependencies"

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(JSON.parse(response.body)).to eq("status" => "ok")
  end

  it "returns 503 when a dependency is degraded" do
    report = instance_double(DependencyHealth::Report, ready?: false)
    allow(DependencyHealth).to receive(:new).and_return(instance_double(DependencyHealth, run: report))

    get "/health/dependencies"

    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body)).to eq("status" => "degraded")
  end
end
