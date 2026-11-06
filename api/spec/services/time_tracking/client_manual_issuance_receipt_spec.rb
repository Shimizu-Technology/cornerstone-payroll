# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe TimeTracking::Client, "historical manual issue descriptors" do
  let(:fixture) { JSON.parse(Rails.root.join("spec/fixtures/manual_allocation_issuance_receipt.json").read) }
  let(:descriptor) { fixture.fetch("replay_response").fetch("integration") }
  let(:source) do
    create(:time_tracking_source, source_type: "aire_services", base_url: "https://time.example.com",
      expected_source_instance_id: descriptor.fetch("source_instance_id"),
      source_protocol: descriptor.fetch("protocol"), source_protocol_version: descriptor.fetch("protocol_version"),
      source_capabilities: descriptor.fetch("capabilities") + [ "unrelated_reporting_v1" ],
      source_policy_constraints: { "time_zones" => [ "Pacific/Guam" ] }, identity_verified_at: Time.current)
  end
  let(:actor) { create(:user, company: source.company, organization: source.company.organization) }
  let(:client) do
    described_class.new(source, actor: actor, destination_policy: TimeTracking::DestinationPolicy.new(
      environment: "test", resolver: ->(_host) { [ "8.8.8.8" ] }))
  end
  let(:url) { "https://time.example.com/api/v1/payroll/cockpit/manual_allocations/901/issue" }

  def issue
    client.issue_payroll_manual_allocation(allocation_id: "901", **fixture.fetch("request").symbolize_keys)
  end

  it "returns the original pinned receipt despite a later verified capability or policy update" do
    receipt = fixture.fetch("replay_response")
    stub_request(:post, url).to_return(status: 200, body: receipt.to_json,
      headers: { "Content-Type" => "application/json" })
    expect(issue).to eq(receipt)
  end

  it "still rejects a historical receipt from another installed source" do
    receipt = fixture.fetch("replay_response").deep_dup
    receipt["integration"]["source_instance_id"] = SecureRandom.uuid
    stub_request(:post, url).to_return(status: 200, body: receipt.to_json,
      headers: { "Content-Type" => "application/json" })
    expect { issue }.to raise_error(TimeTracking::Client::Error, /installation identity changed/)
  end

  it "keeps ordinary commit responses bound to the current verified contract" do
    receipt = { "integration" => descriptor, "manual_allocation" => { "id" => "901", "version" => 0 } }
    stub_request(:post, "https://time.example.com/api/v1/payroll/cockpit/manual_allocations")
      .to_return(status: 200, body: receipt.to_json, headers: { "Content-Type" => "application/json" })
    expect do
      client.commit_payroll_manual_allocation(entry_id: "801", command_id: SecureRandom.uuid,
        expected_version: 2, source_user_uuid: "11111111-1111-4111-8111-111111111111",
        regular_hours: "8", overtime_hours: "0", external_pay_period_id: "67",
        external_payroll_item_id: "91", pay_date: "2026-10-15", reason: "Original exact hours")
    end.to raise_error(TimeTracking::Client::Error, /integration contract changed/)
  end
end
