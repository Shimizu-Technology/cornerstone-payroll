# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Authenticated accounting receipt delivery", type: :request do
  include_context "exact source correction fixtures"
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:jwk) { JWT::JWK.new(key) }
  let(:token) { JWT.encode({ sub: actor.clerk_id, iss: "https://delivery-auth.test", exp: 10.minutes.from_now.to_i }, key, "RS256", { kid: jwk.kid }) }
  let(:headers) { { "Authorization" => "Bearer #{token}", "X-Company-Id" => company.id.to_s } }
  let(:disposition) { confirm }
  let(:delivery_params) { { import_id: next_import.id, disposition_id: disposition.id } }
  around do |example|
    previous_auth = ENV["AUTH_ENABLED"]
    ENV["AUTH_ENABLED"] = "true"
    example.run
  ensure
    ENV["AUTH_ENABLED"] = previous_auth
  end
  before do
    actor.update!(clerk_id: "receipt-operator-#{SecureRandom.uuid}")
    allow_any_instance_of(ApplicationController).to receive(:fetch_jwks).and_return([ jwk.export.deep_stringify_keys ])
    allow_any_instance_of(ApplicationController).to receive(:clerk_issuer).and_return("https://delivery-auth.test")
    delivery_params
  end
  def read_delivery(params = delivery_params, period = next_period)
    get "/api/v1/admin/pay_periods/#{period.id}/time_tracking_correction_delivery", params: params, headers: headers
  end
  def retry_delivery(params = delivery_params)
    post "/api/v1/admin/pay_periods/#{next_period.id}/retry_time_tracking_correction_delivery", params: params, headers: headers, as: :json
  end

  it "shows pending, failed, retried and verified source confirmation without posting accounting money again" do
    receipt = disposition.time_tracking_correction_receipt
    payload = receipt.payload.deep_dup
    event_id = receipt.event_id
    original = original_item.attributes
    counts = [ PayPeriod.count, PayrollItem.count, TimeTrackingCorrectionDisposition.count, TimeTrackingCorrectionReceipt.count ]
    read_delivery
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("disposition", "source_receipt")).to include("status" => "pending", "confirmed_at" => nil)
    receipt.update!(enqueued_at: Time.current)
    allow_any_instance_of(TimeTracking::Client).to receive(:record_accounting_correction_event).and_raise(TimeTracking::Client::Error, "Exact source acknowledgment could not be verified")
    expect { TimeTrackingCorrectionReceiptJob.new.perform(receipt.id) }.to raise_error(TimeTracking::Client::Error)
    read_delivery
    state = JSON.parse(response.body).dig("disposition", "source_receipt")
    expect(state).to include("status" => "error", "error" => "Exact source acknowledgment could not be verified", "can_retry" => true)
    expect(TimeTracking::CorrectionCoverage.new(next_import).presentation.first[:source_receipt][:status]).to eq("error")
    expect { retry_delivery }.to have_enqueued_job(TimeTrackingCorrectionReceiptJob).with(receipt.id).exactly(:once)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("disposition", "source_receipt")).to include("status" => "pending", "error" => nil, "can_retry" => false)
    expect { retry_delivery }.not_to have_enqueued_job(TimeTrackingCorrectionReceiptJob)
    allow_any_instance_of(TimeTracking::Client).to receive(:record_accounting_correction_event).with(**payload.deep_symbolize_keys).and_return({})
    TimeTrackingCorrectionReceiptJob.new.perform(receipt.id)
    read_delivery
    state = JSON.parse(response.body).dig("disposition", "source_receipt")
    expect(state).to include("status" => "confirmed", "error" => nil, "can_retry" => false)
    expect(state["confirmed_at"]).to be_present
    expect { retry_delivery }.not_to have_enqueued_job(TimeTrackingCorrectionReceiptJob)
    expect(receipt.reload.payload).to eq(payload)
    expect(receipt.event_id).to eq(event_id)
    expect([ PayPeriod.count, PayrollItem.count, TimeTrackingCorrectionDisposition.count, TimeTrackingCorrectionReceipt.count ]).to eq(counts)
    expect(original_item.reload.attributes).to eq(original)
    expect(disposition.corrective_payroll_item.check_number).to be_nil
  end

  it "reports failed receipt state in applied-import/pay-period summaries" do
    disposition.time_tracking_correction_receipt.update!(last_error: "Waiting for verified source acknowledgment")
    next_import.update!(status: "applied")
    row = PayPeriodTimeTrackingSummary.call(next_period)[:linked_source_records].first
    expect(row[:correction_dispositions].first[:source_receipt]).to include(status: "error", confirmed_at: nil)
  end

  it "requires authentication and rejects missing, wrong-import and foreign-company scopes" do
    get "/api/v1/admin/pay_periods/#{next_period.id}/time_tracking_correction_delivery", params: delivery_params
    expect(response).to have_http_status(:unauthorized)
    read_delivery(delivery_params.merge(disposition_id: -1))
    expect(response).to have_http_status(:not_found)
    retry_delivery(delivery_params.merge(import_id: original_import.id))
    expect(response).to have_http_status(:not_found)
    read_delivery(delivery_params, create(:pay_period, company: create(:company)))
    expect(response).to have_http_status(:not_found)
    expect(disposition.time_tracking_correction_receipt.reload.delivered_at).to be_nil
  end

  it "ignores client replacement event IDs/payloads and dispatches only the durable receipt" do
    receipt = disposition.time_tracking_correction_receipt
    receipt.update!(last_error: "Verification failed", enqueued_at: Time.current)
    original_payload = receipt.payload.deep_dup
    retry_delivery(delivery_params.merge(event_id: "client-invented", payload: { status: "payment_issued" }))
    expect(response).to have_http_status(:ok)
    expect(receipt.reload.payload).to eq(original_payload)
    expect(receipt.event_id).not_to eq("client-invented")
    expect(TimeTrackingCorrectionReceipt.count).to eq(1)
    expect(TimeTrackingCorrectionDisposition.count).to eq(1)
  end
end
