# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Authenticated exact source correction routes", type: :request do
  include_context "exact source correction fixtures"

  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk) { JWT::JWK.new(key) }
  let(:token) do
    JWT.encode({ sub: actor.clerk_id, iss: "https://bridge-auth.test", exp: 10.minutes.from_now.to_i }, key, "RS256", { kid: jwk.kid })
  end
  let(:headers) { { "Authorization" => "Bearer #{token}", "X-Company-Id" => company.id.to_s } }
  let(:identity_params) { { import_id: next_import.id, source_user_id: "42", source_time_entry_id: "101", line_key: "7:2500" } }

  around do |example|
    previous_auth = ENV["AUTH_ENABLED"]
    ENV["AUTH_ENABLED"] = "true"
    example.run
  ensure
    ENV["AUTH_ENABLED"] = previous_auth
  end

  before do
    actor.update!(clerk_id: "bridge-operator-#{SecureRandom.uuid}")
    allow_any_instance_of(ApplicationController).to receive(:fetch_jwks).and_return([ jwk.export.deep_stringify_keys ])
    allow_any_instance_of(ApplicationController).to receive(:clerk_issuer).and_return("https://bridge-auth.test")
    identity_params
  end

  def preview_route(period = next_period, params: identity_params, request_headers: headers)
    post "/api/v1/admin/pay_periods/#{period.id}/preview_time_tracking_correction", params: params, headers: request_headers, as: :json
  end

  def confirm_route(preview_token, **options)
    post "/api/v1/admin/pay_periods/#{next_period.id}/confirm_time_tracking_correction",
      params: identity_params.merge(preview_token: preview_token, reason: "Verified authenticated source correction",
        acknowledge_accounting_only: true).merge(options), headers: headers, as: :json
  end

  it "dispatches the configured public preview and confirm routes through real JWT authentication and returns one committed disposition" do
    expect { preview_route }.not_to change(PayPeriod, :count)
    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body).fetch("correction")
    expect(json["preview_token"]).to be_present
    expect(json.dig("deltas", "gross_pay")).to eq(-25)
    expect { confirm_route(json["preview_token"]) }.to change(TimeTrackingCorrectionDisposition, :count).by(1)
    expect(response).to have_http_status(:ok)
    result = JSON.parse(response.body)
    expect(result["disposition_id"]).to be_present
    expect(result.dig("import", "correction_dispositions").size).to eq(1)
    expect(result.dig("import", "processed_payload", "rows")).to eq([])
    confirm_route(json["preview_token"])
    expect(response).to have_http_status(:ok)
    expect(TimeTrackingCorrectionDisposition.count).to eq(1)
  end

  context "a multi-day original paycheck" do
    let(:original_regular_hours) { 10 }
    let(:original_import) do
      make_import(original_period, 4, "current", "ORIGINAL", status: "applied", daily_lines: [
        { source_time_entry_id: "101", total_hours: 4, regular_hours: 4, overtime_hours: 0 },
        { source_time_entry_id: "102", line_key: "7:2500:day2", original_work_date: "2026-10-06",
          total_hours: 6, regular_hours: 6, overtime_hours: 0 }
      ])
    end

    it "posts one reviewed day through the authenticated HTTP API while preserving the original daily union" do
      old_allocations = original_item.time_tracking_entry_allocations.order(:id).map(&:attributes)
      preview_route
      expect(response).to have_http_status(:ok)
      correction = JSON.parse(response.body).fetch("correction")
      expect(correction.dig("original", "gross_pay")).to eq(250)
      expect(correction.dig("corrected", "gross_pay")).to eq(225)
      confirm_route(correction["preview_token"])
      expect(response).to have_http_status(:ok)
      expect(TimeTrackingCorrectionDisposition.first.corrective_payroll_item.gross_pay).to eq(-25)
      expect(original_item.reload.hours_worked).to eq(10)
      expect(original_item.time_tracking_entry_allocations.order(:id).map(&:attributes)).to eq(old_allocations)
    end
  end

  it "requires authentication for both routed actions" do
    [ "preview", "confirm" ].each do |action|
      post "/api/v1/admin/pay_periods/#{next_period.id}/#{action}_time_tracking_correction", params: identity_params, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "rejects a foreign pay period and an import belonging to another period" do
    foreign_period = create(:pay_period, company: create(:company))
    preview_route(foreign_period)
    expect(response).to have_http_status(:not_found)
    preview_route(params: identity_params.merge(import_id: original_import.id))
    expect(response).to have_http_status(:not_found)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "returns controlled 404 responses for missing imports on both actions" do
    preview_route(params: identity_params.merge(import_id: -1))
    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["error"]).to eq("Time tracking import not found")
    confirm_route("missing", import_id: -1)
    expect(response).to have_http_status(:not_found)
  end

  it "rejects a foreign source bound to an otherwise tenant-owned import before money changes" do
    foreign_source = create(:time_tracking_source, company: create(:company))
    invalid = create(:time_tracking_import, pay_period: next_period, time_tracking_source: foreign_source)
    preview_route(params: identity_params.merge(import_id: invalid.id))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
    expect(PayrollItem.where(correction_for_payroll_item_id: original_item.id)).not_to exist
  end

  it "rejects an inactive or downgraded principal after preview" do
    preview_route
    expect(response).to have_http_status(:ok)
    proof = JSON.parse(response.body).dig("correction", "preview_token")
    actor.update!(active: false)
    confirm_route(proof)
    expect(response).to have_http_status(:unauthorized)
    actor.update!(active: true, role: "employee")
    confirm_route(proof)
    expect(response).to have_http_status(:forbidden)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end

  it "returns 422 for a stale signed preview without creating accounting or financial records" do
    preview_route
    proof = JSON.parse(response.body).dig("correction", "preview_token")
    original_item.update_columns(correction_reason: "Changed historical item after review")
    confirm_route(proof)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to match(/history changed/)
    expect(TimeTrackingCorrectionDisposition.count).to eq(0)
  end
end
