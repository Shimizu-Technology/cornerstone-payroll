# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe TimeTracking::Client, "saved payment-resolution actor" do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  it "retains account-link actor mode rather than falling back to a different delegation" do
    original = described_class.new(source, actor: actor)
    binding = original.payroll_command_binding
    probe = instance_double(described_class)
    allow(described_class).to receive(:new).with(source).and_return(probe)
    allow(probe).to receive(:payroll_account_link).with(external_actor_id: actor.id).and_return("account_link" => { "connected" => false })
    expect { described_class.for_saved_payroll_actor(source, actor: actor, binding: binding) }
      .to raise_error(described_class::Error, /original payroll operator account/)
    expect(binding).to eq("kind" => "account_link", "actor_id" => actor.id)
  end

  it "keeps the same encrypted delegation identity and rejects changed credentials or another operator" do
    delegation = create(:time_tracking_delegation, company: company, time_tracking_source: source, user: actor, token: "original-test-delegation")
    original = described_class.new(source, delegation: delegation)
    binding = original.payroll_command_binding
    saved = described_class.for_saved_payroll_actor(source, actor: actor, binding: binding)
    expect(saved.payroll_command_binding).to eq(binding)
    expect(binding.to_json).not_to include("original-test-delegation")
    delegation.update!(token: "changed-test-delegation")
    expect { described_class.for_saved_payroll_actor(source, actor: actor, binding: binding) }.to raise_error(described_class::Error, /delegation changed/)
    other = create(:user, company: company, organization: company.organization, role: "admin")
    expect { described_class.for_saved_payroll_actor(source, actor: other, binding: binding) }.to raise_error(described_class::Error, /original payroll operator/)
  end

  it "uses generic actor headers and replays a captured resolution contract after current capability changes" do
    compatible = create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "compatible_clock",
      base_url: "https://clock.example.test", shared_secret: "test-secret", expected_source_instance_id: SecureRandom.uuid,
      source_protocol: "shimizu_time_payroll", source_protocol_version: "1.0", identity_verified_at: Time.current,
      source_capabilities: %w[payment_attestations payment_attestation_resolution_v1])
    integration = { protocol: compatible.source_protocol, protocol_version: compatible.source_protocol_version,
      source_instance_id: compatible.expected_source_instance_id, source_type: "compatible_clock",
      capabilities: compatible.source_capabilities, policy_constraints: compatible.source_policy_constraints }
    client = described_class.new(compatible, actor: actor,
      destination_policy: TimeTracking::DestinationPolicy.new(environment: "test", resolver: ->(_host) { [ "8.8.8.8" ] }))
    command = { command_id: SecureRandom.uuid, expected_version: 3, reason: "Original saved exact payment match" }
    request = stub_request(:post, "https://clock.example.test/api/v1/payroll/cockpit/payment_attestations/501/resolve")
      .with(headers: { "X-Payroll-Actor-Id" => actor.id.to_s }, body: command.to_json)
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { integration: integration }.to_json)
    client.resolve_payroll_payment_attestation(attestation_id: "501", **command)
    compatible.update!(source_capabilities: [ "payment_attestations" ])
    expect { client.resolve_payroll_payment_attestation(attestation_id: "501", **command) }
      .to raise_error(described_class::Error, /does not support/)
    client.resolve_payroll_payment_attestation(attestation_id: "501", verified_saved_capability: true, **command)
    expect(request).to have_been_requested.twice
  end
end
