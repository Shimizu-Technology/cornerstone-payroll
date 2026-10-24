# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCockpit::Presenter do
  it "preserves the upstream sequence of tied audit events while decorating settlement employees" do
    source = create(:time_tracking_source, source_type: "aire_services")
    events = [
      { "id" => "ffffffff-ffff-4fff-8fff-ffffffffffff", "event_type" => "opened", "occurred_at" => "2026-10-24T09:00:00Z" },
      { "id" => "00000000-0000-4000-8000-000000000000", "event_type" => "routed", "occurred_at" => "2026-10-24T09:00:00Z" }
    ]
    payload = { "settlement_cases" => [ { "id" => SecureRandom.uuid, "status" => "scheduled", "events" => events,
      "employee" => { "payroll_integration_id" => SecureRandom.uuid } } ] }
    original = payload.deep_dup

    result = described_class.new(source: source).settlement_cases(payload)
    expect(result["settlement_cases"].first["events"]).to eq(events)
    expect(result["settlement_cases"].first.dig("employee", "cornerstone", "status")).to eq("unmapped")
    expect(payload).to eq(original)
  end
end
