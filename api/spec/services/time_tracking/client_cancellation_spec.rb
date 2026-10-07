# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe TimeTracking::Client do
  let(:source) do
    create(:time_tracking_source, source_type: "aire_services", base_url: "https://time.example.com",
      expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "1.0", identity_verified_at: Time.current,
      source_capabilities: %w[manual_allocations exact_line_receipts_v2 payment_cancellation_v1])
  end
  let(:actor) { create(:user, company: source.company, organization: source.company.organization) }
  let(:client) do
    described_class.new(source, actor: actor, destination_policy: TimeTracking::DestinationPolicy.new(
      environment: "test", resolver: ->(_host) { [ "8.8.8.8" ] }))
  end
  let(:descriptor) do
    { protocol: "shimizu_time_payroll", protocol_version: "1.0", source_instance_id: source.expected_source_instance_id,
      capabilities: source.source_capabilities, source_type: "aire_services" }
  end

  def cancel
    client.cancel_payroll_manual_allocation_payment(allocation_id: "501", command_id: "synthetic-cancel-command",
      expected_version: 1, occurred_at: "2026-10-01T07:00:00Z", reason: "Recovered original physical check",
      cancellation_evidence_reference: "Synthetic recovered check 8000", payment_method: "paper_check",
      payment_reference: "8000", payment_effective_on: "2026-09-30")
  end

  it "requires a verified descriptor on new manual cancellation acknowledgements, even for AIRE" do
    request = stub_request(:post, "https://time.example.com/api/v1/payroll/cockpit/manual_allocations/501/cancel_payment")
      .with(body: hash_including("expected_version" => 1, "payment_reference" => "8000",
        "cancellation_evidence_reference" => "Synthetic recovered check 8000"))
      .to_return({ status: 200, body: { manual_allocation: { id: "501", version: 2, status: "committed" } }.to_json,
          headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { integration: descriptor, command: { id: "synthetic-cancel-command" }, manual_allocation: { id: "501", version: 2, status: "committed" } }.to_json,
          headers: { "Content-Type" => "application/json" } })
    expect { cancel }.to raise_error(TimeTracking::Client::Error, /omitted its pinned installation identity/)
    expect(cancel.dig("manual_allocation", "status")).to eq("committed")
    expect(request).to have_been_requested.twice
  end

  it "rejects a changed cancellation descriptor and never sends an unsupported operation" do
    stub_request(:post, "https://time.example.com/api/v1/payroll/cockpit/manual_allocations/501/cancel_payment")
      .to_return(status: 200, body: { integration: descriptor.merge(capabilities: [ "manual_allocations" ]) }.to_json,
        headers: { "Content-Type" => "application/json" })
    expect { cancel }.to raise_error(TimeTracking::Client::Error, /integration contract changed/)
    source.update!(source_capabilities: [ "manual_allocations" ])
    expect { cancel }.to raise_error(TimeTracking::Client::Error, /does not support payment cancellation/)
  end

  it "requires the same verified acknowledgement for direct exact-line cancellation" do
    stub_request(:post, "https://time.example.com/api/v1/payroll/batches/AIRE-PAY-001/processing_events")
      .to_return(status: 200, body: {}.to_json, headers: { "Content-Type" => "application/json" })
    expect { client.record_payroll_entry_processing_event(batch_id: "AIRE-PAY-001", event_id: "cancel-exact-line",
      status: "payment_cancelled", occurred_at: "2026-10-01T07:00:00Z", external_pay_period_id: "10",
      external_payroll_item_id: "20", source_time_entry_id: "41") }
      .to raise_error(TimeTracking::Client::Error, /omitted its pinned installation identity/)
  end
  def direct_cancel(expected)
    client.record_payroll_entry_processing_event(batch_id: "AIRE-PAY-001", **expected)
  end

  it "binds cancellation acknowledgement to the exact line, hours, original instrument, evidence and date" do
    expected = { event_id: "cancel-exact-line", status: "payment_cancelled", occurred_at: "2026-10-01T07:00:00.123456Z",
      external_pay_period_id: "10", external_payroll_item_id: "20", source_time_entry_id: "41",
      source_user_uuid: SecureRandom.uuid, contract_version: "2.0", source_line_key: "category:1", source_kind: "current",
      total_hours: "6.00", regular_hours: "5.00", overtime_hours: "1.00", payment_method: "paper_check", payment_reference: "8000",
      payment_effective_on: "2026-09-30", metadata: { cancelled_payment_event_id: "original-issued-line",
        cancellation_evidence_reference: "Synthetic recovered check 8000", payroll_obligation_retained: true } }
    receipt = expected.merge(external_system: "cornerstone_payroll", occurred_at: "2026-10-01T17:00:00.123456+10:00").deep_stringify_keys
    variants = [ { "entry_processing" => receipt.merge("occurred_at" => "2026-10-01T07:00:00.123455Z") }, {}, { "entry_processing" => "invalid" }, { "entry_processing" => receipt.merge("event_id" => "different-event") },
      { "entry_processing" => receipt.merge("source_line_key" => "category:2") },
      { "entry_processing" => receipt.merge("source_user_uuid" => SecureRandom.uuid) },
      { "entry_processing" => receipt.merge("external_payroll_item_id" => "21") },
      { "entry_processing" => receipt.merge("regular_hours" => "6.00") },
      { "entry_processing" => receipt.merge("status" => "payment_issued") },
      { "entry_processing" => receipt.except("payment_effective_on") },
      { "entry_processing" => receipt.merge("payment_reference" => "8001") },
      { "entry_processing" => receipt.merge("metadata" => receipt.fetch("metadata").merge("cancellation_evidence_reference" => "different proof")) } ]
    request = stub_request(:post, "https://time.example.com/api/v1/payroll/batches/AIRE-PAY-001/processing_events")
      .to_return(*variants.map { |variant| { status: 200, body: variant.merge("integration" => descriptor).to_json,
        headers: { "Content-Type" => "application/json" } } },
        { status: 200, body: { integration: descriptor, entry_processing: receipt }.to_json,
          headers: { "Content-Type" => "application/json" } })
    variants.each { expect { direct_cancel(expected) }.to raise_error(TimeTracking::Client::Error, /cancelled payment receipt/) }
    expect(direct_cancel(expected).dig("entry_processing", "event_id")).to eq(expected[:event_id])
    expect(request).to have_been_requested.times(variants.length + 1)
  end

end
