# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ConnectionIdentity do
  let(:source) { create(:time_tracking_source, source_type: "custom") }
  let(:instance_id) { SecureRandom.uuid }
  let(:payload) do
    {
      "integration" => {
        "protocol" => "shimizu_time_payroll",
        "protocol_version" => "1.0",
        "source_instance_id" => instance_id,
        "capabilities" => %w[time_summary_v1 exact_line_receipts_v2]
      }
    }
  end

  it "pins a verified installation identity and normalized capabilities" do
    now = Time.zone.parse("2026-10-01 09:00:00")

    result = described_class.verify_and_pin!(source: source, payload: payload, now: now)

    expect(result.legacy).to be(false)
    expect(source.reload).to have_attributes(
      expected_source_instance_id: instance_id,
      source_protocol: "shimizu_time_payroll",
      source_protocol_version: "1.0",
      source_capabilities: %w[exact_line_receipts_v2 time_summary_v1],
      identity_verified_at: now
    )
  end

  it "rejects an identity change after the connection is pinned" do
    described_class.verify_and_pin!(source: source, payload: payload)
    changed = payload.deep_dup
    changed["integration"]["source_instance_id"] = SecureRandom.uuid

    expect do
      described_class.validate!(source: source.reload, payload: changed)
    end.to raise_error(/installation identity changed/i)
  end

  it "keeps legacy sources compatible until an identity has been pinned" do
    result = described_class.validate!(source: source, payload: {})

    expect(result.legacy).to be(true)
    source.update!(
      expected_source_instance_id: instance_id,
      source_protocol: "shimizu_time_payroll",
      source_protocol_version: "1.0",
      source_capabilities: [ "time_summary_v1" ],
      identity_verified_at: Time.current
    )

    expect do
      described_class.validate!(source: source, payload: {})
    end.to raise_error(/omitted its pinned installation identity/i)
  end

  it "rejects malformed capability declarations" do
    payload["integration"]["capabilities"] = [ "time_summary_v1", "Bad Capability" ]

    expect do
      described_class.validate!(source: source, payload: payload)
    end.to raise_error(/invalid integration capabilities/i)
  end
end
