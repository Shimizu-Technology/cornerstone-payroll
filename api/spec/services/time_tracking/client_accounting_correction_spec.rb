# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe TimeTracking::Client do
  let(:source) do
    create(:time_tracking_source, source_type: "custom", base_url: "https://time.example.com",
      remote_source_identifier: "fixture_time", expected_source_instance_id: SecureRandom.uuid,
      source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0", identity_verified_at: Time.current,
      source_capabilities: %w[exact_line_receipts_v2])
  end
  let(:client) do
    described_class.new(source, destination_policy: TimeTracking::DestinationPolicy.new(environment: "test", resolver: ->(_host) { [ "8.8.8.8" ] }))
  end
  let(:descriptor) do
    { protocol: "shimizu_time_payroll", protocol_version: "1.0", source_instance_id: source.expected_source_instance_id,
      source_type: "fixture_time", capabilities: source.source_capabilities }
  end
  let(:expected) do
    { batch_id: "BATCH-1", event_id: "accounting-event", status: "committed", occurred_at: "2026-10-01T07:00:00.123456Z",
      external_pay_period_id: "100", external_payroll_item_id: "101", source_time_entry_id: "41",
      source_user_uuid: SecureRandom.uuid, contract_version: "2.0", source_line_key: "category:1", source_kind: "correction",
      total_hours: "-1.00", regular_hours: "-1.00", overtime_hours: "0.00", metadata: { accounting_only: true,
        correction_disposition_id: "1", original_pay_period_id: "10", original_payroll_item_id: "11",
        corrective_pay_period_id: "100", corrective_payroll_item_id: "101" } }
  end

  it "requires the exact verified noncash committed receipt and omits all payment and money fields" do
    receipt = expected.except(:batch_id).merge(external_system: "cornerstone_payroll").deep_stringify_keys
    variants = [ {}, { "entry_processing" => "invalid" }, { "entry_processing" => receipt.merge("source_user_uuid" => SecureRandom.uuid) },
      { "entry_processing" => receipt.merge("external_pay_period_id" => "10") },
      { "entry_processing" => receipt.merge("source_line_key" => "wrong") },
      { "entry_processing" => receipt.merge("regular_hours" => "1.00") },
      { "entry_processing" => receipt.merge("status" => "payment_issued") },
      { "entry_processing" => receipt.merge("payment_method" => "paper_check") },
      { "entry_processing" => receipt.merge("metadata" => receipt["metadata"].merge("accounting_only" => false)) },
      { "entry_processing" => receipt.merge("metadata" => receipt["metadata"].merge("recovered" => true)) },
      { "entry_processing" => receipt.merge("occurred_at" => "2026-10-01T07:00:00.123455Z") } ]
    request = stub_request(:post, "https://time.example.com/api/v1/payroll/batches/BATCH-1/processing_events")
      .with { |http| body = JSON.parse(http.body); body.keys.grep(/payment|gross|net|tax/).empty? && body["external_pay_period_id"] == "100" }
      .to_return(*variants.map { |variant| { status: 200, body: variant.merge("integration" => descriptor).to_json,
        headers: { "Content-Type" => "application/json" } } },
        { status: 200, body: { integration: descriptor, entry_processing: receipt }.to_json, headers: { "Content-Type" => "application/json" } })
    variants.each { expect { client.record_accounting_correction_event(**expected) }.to raise_error(TimeTracking::Client::Error, /accounting correction/) }
    expect(client.record_accounting_correction_event(**expected).dig("entry_processing", "event_id")).to eq("accounting-event")
    expect(request).to have_been_requested.times(variants.size + 1)
  end

  it "rejects absent, changed-installation, or changed-capability acknowledgment descriptors" do
    receipt = expected.except(:batch_id).merge(external_system: "cornerstone_payroll")
    stub_request(:post, "https://time.example.com/api/v1/payroll/batches/BATCH-1/processing_events")
      .to_return({ status: 200, body: { entry_processing: receipt }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { integration: descriptor.merge(source_instance_id: SecureRandom.uuid), entry_processing: receipt }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { integration: descriptor.merge(capabilities: []), entry_processing: receipt }.to_json, headers: { "Content-Type" => "application/json" } })
    3.times { expect { client.record_accounting_correction_event(**expected) }.to raise_error(TimeTracking::Client::Error) }
  end
end
