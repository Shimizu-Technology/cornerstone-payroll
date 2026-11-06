# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"
require "tempfile"

RSpec.describe ActionController::Base, type: :controller do
  controller do
    include StagingArtifactDelivery
    rescue_from StagingOutboundPolicy::Blocked do |error|
      render json: { error: error.message, staging: true }, status: :service_unavailable
    end

    def csv
      send_data "Name\nJos\xC3\xA9".b, filename: "people.csv", type: "text/csv"
    end

    def pdf
      send_data Prawn::Document.new { text "Synthetic report" }.render, filename: "report.pdf", type: "application/pdf"
    end

    def stored_csv
      Tempfile.create([ "synthetic", ".csv" ]) do |file|
        file.binmode
        file.write("Name\nSynthetic")
        file.flush
        send_file file.path, filename: params[:filename] || "stored.csv", type: params[:filename] ? "application/octet-stream" : "text/csv"
      end
    end

    def blocked
      send_data "bank data", filename: "bank.ach", type: "text/plain"
    end
  end

  around do |example|
    old = ENV["DEPLOYMENT_ENV"]
    ENV["DEPLOYMENT_ENV"] = "staging"
    example.run
  ensure
    old ? ENV["DEPLOYMENT_ENV"] = old : ENV.delete("DEPLOYMENT_ENV")
  end

  before do
    routes.draw do
      %w[csv pdf stored_csv blocked].each { |action| get "anonymous/#{action}" => "anonymous##{action}" }
    end
  end

  it "marks send_data CSV bytes and filename" do
    get :csv
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(StagingOutboundPolicy::LABEL.b + "\nName\nJos\xC3\xA9".b)
    expect(response.headers["Content-Disposition"]).to include("STAGING_people.csv")
  end

  it "marks a PDF controller download and filename" do
    get :pdf
    expect(response).to have_http_status(:ok)
    expect(PDF::Reader.new(StringIO.new(response.body)).pages.first.text).to include(StagingOutboundPolicy::LABEL)
    expect(response.headers["Content-Disposition"]).to include("STAGING_report.pdf")
  end

  it "marks send_file bytes and filename" do
    get :stored_csv
    expect(response.body.b).to start_with(StagingOutboundPolicy::LABEL.b)
    expect(response.headers["Content-Disposition"]).to include("STAGING_stored.csv")
  end

  it "returns a clear 503 instead of unmarkable bytes" do
    get :blocked
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to include("staging" => true)
    expect(response.body).not_to include("bank data")
  end
  it "blocks send_file for an unsupported format" do
    get :stored_csv, params: { filename: "bank.ach" }
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to include("staging" => true)
    expect(response.body).not_to include("Name")
  end
end
