# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Financial correction receipt contract" do
  let(:fixture) { JSON.parse(File.read(Rails.root.join("spec/fixtures/payroll_obligation_correction_v1.json"))) }
  let(:source) do
    create(:time_tracking_source, source_type: "custom", remote_source_identifier: "aire_services",
      source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0",
      expected_source_instance_id: fixture.dig("request", "obligation_correction", "source_instance_id"),
      identity_verified_at: Time.current, source_capabilities: %w[payroll_obligation_correction_v1])
  end
  let(:client) { TimeTracking::Client.new(source) }

  it "independently validates the sealed Source fixture and its canonical digest" do
    expect(TimeTracking::CanonicalPayload.checksum(fixture.fetch("request"))).to eq("da6f9129aa9fc9a10bd6441602b23185121395f461283429bb0bc14400cd5ed2")
    expect(client.validate_financial_correction_receipt!(fixture.fetch("response"), expected: fixture.fetch("request"))).to be(true)
  end

  [ nil, [], 1, "malformed" ].each do |metadata|
    it "rejects #{metadata.inspect} metadata with a controlled client error" do
      response = fixture.fetch("response").deep_dup
      response["entry_processing"]["metadata"] = metadata
      expect { client.validate_financial_correction_receipt!(response, expected: fixture.fetch("request")) }.to raise_error(TimeTracking::Client::Error)
    end
  end

  %w[external_pay_period_id external_payroll_item_id source_line_key source_user_uuid status].each do |key|
    it "rejects a mismatched #{key} instead of marking delivery accepted" do
      response = fixture.fetch("response").deep_dup
      response["entry_processing"][key] = "wrong"
      expect { client.validate_financial_correction_receipt!(response, expected: fixture.fetch("request")) }.to raise_error(TimeTracking::Client::Error)
    end
  end

  it "rejects a changed binding ID on a known bound payment callback" do
    expect { client.validate_financial_correction_receipt!(fixture.fetch("response"), expected: fixture.fetch("request"), binding_id: "99") }.to raise_error(TimeTracking::Client::Error)
  end

  %w[payment_prepared payment_issued payment_cancelled].each do |status|
    it "accepts the actual Source metadata enrichment for #{status}, with no arbitrary extras" do
      request = fixture.fetch("request").except("obligation_correction").merge("status" => status,
        "payment_method" => "paper_check", "payment_reference" => "30001", "payment_effective_on" => "2026-11-22")
      response = fixture.fetch("response").deep_dup
      response["entry_processing"].merge!(request)
      response["entry_processing"]["payment_effective_on"] = "2026-11-22"
      response["entry_processing"]["metadata"] = { "payment_effective_on" => "2026-11-22" }
      if status == "payment_cancelled"
        request["metadata"] = { "cancelled_payment_event_id" => "prior-prepared", "cancellation_evidence_reference" => "SYNTHETIC-CANCEL", "payroll_obligation_retained" => true }
        response["entry_processing"]["metadata"] = request["metadata"].merge("payment_effective_on" => "2026-11-22", "original_payment_effective_on_known" => true, "original_payment_effective_on" => "2026-11-22")
      end
      expect(client.validate_financial_correction_receipt!(response, expected: request, link_request: fixture.fetch("request"), binding_id: "1")).to be(true)
      response["entry_processing"]["metadata"]["unexpected"] = "do not accept"
      expect { client.validate_financial_correction_receipt!(response, expected: request, link_request: fixture.fetch("request")) }.to raise_error(TimeTracking::Client::Error)
    end
  end

  it "rejects absent or wrong lineage command, digest or Source installation" do
    [ [ "request_digest", "wrong" ], [ "command", {} ] ].each do |key, value|
      response = fixture.fetch("response").deep_dup
      response["obligation_correction"][key] = value
      expect { client.validate_financial_correction_receipt!(response, expected: fixture.fetch("request")) }.to raise_error(TimeTracking::Client::Error)
    end
    response = fixture.fetch("response").deep_dup
    response["integration"]["source_instance_id"] = SecureRandom.uuid
    expect { client.validate_financial_correction_receipt!(response, expected: fixture.fetch("request")) }.to raise_error(TimeTracking::Client::Error)
  end
  it "uses the versioned obligation route without falling back to an older receiver" do
    request = fixture.fetch("request")
    expect(client).to receive(:request_json).with(
      have_attributes(path: %r{/api/v1/payroll/batches/batch-1/obligation_events\z}),
      validate_source: false, method: :post, body: request
    ).and_raise(TimeTracking::Client::Error.new("Not found", response_status: 404))
    expect { client.record_financial_correction_event(batch_id: "batch-1", payload: request, link_request: request) }
      .to raise_error(TimeTracking::Client::Error) { |error| expect(error.response_status).to eq(404) }
  end

  it "keeps unknown cancellation dates explicit and does not carry cancellation metadata into replacement payment" do
    request = fixture.fetch("request").except("obligation_correction").merge("status" => "payment_cancelled",
      "payment_method" => "paper_check", "payment_reference" => "30001",
      "metadata" => { "cancelled_payment_event_id" => "prior-prepared", "cancellation_evidence_reference" => "SYNTHETIC-CANCEL" })
    response = fixture.fetch("response").deep_dup
    response["entry_processing"].merge!(request)
    response["entry_processing"]["metadata"] = request["metadata"].merge("original_payment_effective_on_known" => false, "original_payment_effective_on" => nil)
    expect(client.validate_financial_correction_receipt!(response, expected: request, link_request: fixture.fetch("request"))).to be(true)
    replacement = request.merge("status" => "payment_issued", "payment_method" => "direct_deposit", "payment_reference" => "SYNTHETIC-BANK", "payment_effective_on" => "2026-11-22", "metadata" => {})
    response["entry_processing"].merge!(replacement)
    response["entry_processing"]["metadata"] = { "payment_effective_on" => "2026-11-22" }
    expect(client.validate_financial_correction_receipt!(response, expected: replacement, link_request: fixture.fetch("request"))).to be(true)
    response["entry_processing"]["metadata"]["original_payment_effective_on_known"] = false
    expect { client.validate_financial_correction_receipt!(response, expected: replacement, link_request: fixture.fetch("request")) }.to raise_error(TimeTracking::Client::Error)
  end
end
