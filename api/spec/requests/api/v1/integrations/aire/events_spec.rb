# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Integrations::Aire::Events", type: :request do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", shared_secret: "integration-secret") }
  let(:pay_period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 15), pay_date: Date.new(2026, 10, 25))
  end
  let(:calendar_period) { create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: pay_period) }
  let(:publication) { create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar_period, delivery_status: "delivered") }
  let(:batch_payload) { build_aire_batch_payload }
  let(:event_payload) { build_aire_finalized_event(calendar_period: calendar_period, publication: publication, batch_payload: batch_payload) }
  let(:headers) do
    {
      "CONTENT_TYPE" => "application/json",
      "X-Shared-Secret" => "integration-secret",
      "Idempotency-Key" => event_payload.fetch("event_id")
    }
  end

  before do
    allow(AirePayrollEvent).to receive(:dispatch_one!)
  end

  it "returns a retryable response before parsing or persisting an event when paused" do
    allow(ConnectedPayrollMode).to receive(:enabled?).and_return(false)
    expect(AirePayrollEvents::Receiver).not_to receive(:new)
    expect do
      post "/api/v1/integrations/aire/events", params: "{broken json", headers: { "CONTENT_TYPE" => "application/json" }
    end.not_to change(AirePayrollEvent, :count)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(response.parsed_body).to include("error" => "Connected payroll is paused")
  end

  it "rejects valid webhook deliveries on both routes without persisting or dispatching a verification job" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return("true")

    %w[/api/v1/integrations/aire/events /api/v1/integrations/time_payroll/events].each do |path|
      expect do
        post path, params: event_payload.to_json, headers: headers
      end.not_to change(AirePayrollEvent, :count)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("60")
      expect(response.parsed_body["code"]).to eq("write_maintenance")
    end
    expect(AirePayrollEvent).not_to have_received(:dispatch_one!)

    allow(ENV).to receive(:[]).with("WRITE_MAINTENANCE").and_return("false")
    post "/api/v1/integrations/aire/events", params: event_payload.to_json, headers: headers
    expect(response).to have_http_status(:accepted)
    expect(AirePayrollEvent).to have_received(:dispatch_one!).once
  end

  it "accepts and idempotently acknowledges a valid event without Clerk authentication" do
    post "/api/v1/integrations/aire/events", params: event_payload.to_json, headers: headers

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include(
      "event_id" => event_payload.fetch("event_id"),
      "status" => "pending",
      "idempotent" => false
    )
    audit = AuditLog.find_by!(action: "aire_payroll_event#received")
    expect(audit).to have_attributes(user_id: nil, actor_type: "source_system", actor_id: source.id.to_s,
      actor_name: "AIRE System", record_id: AirePayrollEvent.sole.id)
    expect(Current.actor).to be_nil
    expect(AirePayrollEvent.sole.payload).to eq(event_payload)
    expect(AirePayrollEvent.sole.payload).not_to have_key("event")
    expect(AirePayrollEvent).to have_received(:dispatch_one!).with(AirePayrollEvent.sole.id, now: kind_of(Time)).once

    post "/api/v1/integrations/aire/events", params: event_payload.to_json, headers: headers
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body.fetch("idempotent")).to be(true)
    expect(AuditLog.where(action: "aire_payroll_event#received").sole).to eq(audit)
    expect(AirePayrollEvent).to have_received(:dispatch_one!).once
  end

  it "accepts AIRE's UTC Batch v2 cutoff when it is the same Guam instant" do
    expect(event_payload.dig("payroll_batch", "cutoff_at")).to eq("2026-10-18T07:00:00Z")
    expect(publication.payload.fetch("cutoff_at")).to eq("2026-10-18T17:00:00+10:00")

    post "/api/v1/integrations/aire/events", params: event_payload.to_json, headers: headers

    expect(response).to have_http_status(:accepted)
  end

  it "rejects a second event identity for an already-received immutable batch" do
    post "/api/v1/integrations/aire/events", params: event_payload.to_json, headers: headers
    second_event = event_payload.merge("event_id" => SecureRandom.uuid)

    post "/api/v1/integrations/aire/events", params: second_event.to_json,
         headers: headers.merge("Idempotency-Key" => second_event.fetch("event_id"))

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to include("already finalized")
    expect(AirePayrollEvent.count).to eq(1)
  end

  it "fails closed for a missing or incorrect source secret" do
    post "/api/v1/integrations/aire/events", params: event_payload.to_json,
         headers: headers.except("X-Shared-Secret")
    expect(response).to have_http_status(:unauthorized)

    post "/api/v1/integrations/aire/events", params: event_payload.to_json,
         headers: headers.merge("X-Shared-Secret" => "wrong")
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects an idempotency-key mismatch" do
    post "/api/v1/integrations/aire/events", params: event_payload.to_json,
         headers: headers.merge("Idempotency-Key" => SecureRandom.uuid)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Idempotency-Key")
  end

  it "returns a stable bad-request response for malformed JSON" do
    post "/api/v1/integrations/aire/events", params: '{"event_id":', headers: headers

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.fetch("error")).to eq("Request body must be valid JSON")
    expect(AirePayrollEvent.count).to eq(0)
  end
end
