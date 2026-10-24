# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "staging artifact delivery", type: :request do
  around do |example|
    old = ENV.to_h
    ENV["DEPLOYMENT_ENV"] = "staging"
    example.run
  ensure
    ENV.replace(old)
  end

  it "blocks framework blob redirects before resolving signed IDs" do
    get "/rails/active_storage/blobs/redirect/invalid-synthetic-id/private.pdf"
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to include("staging" => true)
    expect(response.headers["Location"]).to be_nil
  end

  it "blocks framework direct uploads before creating blob metadata" do
    expect_any_instance_of(ActiveStorage::DirectUploadsController).not_to receive(:blob_args)
    post "/rails/active_storage/direct_uploads", params: { blob: { filename: "private.pdf", byte_size: 1, checksum: "x", content_type: "application/pdf" } }
    expect(response).to have_http_status(:service_unavailable)
  end
  it "also blocks proxy, disk and representation routes before blob lookup" do
    %w[/rails/active_storage/blobs/proxy/invalid/private.pdf /rails/active_storage/disk/invalid/private.pdf /rails/active_storage/representations/redirect/invalid/variant/private.png /rails/active_storage/representations/proxy/invalid/variant/private.png].each do |path|
      get path
      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Location"]).to be_nil
    end
  end
end
