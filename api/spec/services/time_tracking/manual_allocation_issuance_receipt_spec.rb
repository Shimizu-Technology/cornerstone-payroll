# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Manual allocation issuance receipts" do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let(:employee) { create(:employee, company: company) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) { create(:payroll_item, :with_check, company: company, employee: employee, pay_period: period) }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "aire_services",
      expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "1.0", identity_verified_at: Time.current,
      source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES)
  end
  let!(:allocation) do
    TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
      pay_period: period, payroll_item: item, employee: employee, created_by: actor,
      source_user_uuid: SecureRandom.uuid, source_time_entry_id: "41", source_time_entry_version: 2,
      original_work_date: period.start_date, regular_hours: 5, overtime_hours: 1,
      reconciliation_note: "Exact synthetic source work and delivered original check", status: "committed",
      remote_allocation_id: "501", remote_version: 0)
  end
  let(:client) { instance_double(TimeTracking::Client) }
  let(:service) { TimeTracking::ManualAllocationService.new(pay_period: period, source: source, actor: actor) }

  before do
    item.check_events.create!(event_type: "delivered", user: actor, check_number: item.check_number,
      effective_on: PayrollBusinessClock.today)
    allow(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: actor).and_return(client)
  end

  mutations = {
    "missing status" => ->(r) { r["manual_allocation"].delete("status") },
    "committed status" => ->(r) { r["manual_allocation"]["status"] = "committed" },
    "nonadvancing version" => ->(r) { r["manual_allocation"]["version"] = 0 },
    "later current-state version without matching command result" => ->(r) { r["manual_allocation"]["version"] = 4 },
    "wrong work identity" => ->(r) { r["manual_allocation"]["source_time_entry_id"] = "42" },
    "wrong work version" => ->(r) { r["manual_allocation"]["source_time_entry_version"] = 3 },
    "wrong person UUID" => ->(r) { r["manual_allocation"]["source_user_uuid"] = SecureRandom.uuid },
    "wrong work date" => ->(r) { r["manual_allocation"]["work_date"] = "2001-01-01" },
    "wrong payday" => ->(r) { r["manual_allocation"]["pay_date"] = "2001-01-01" },
    "wrong period owner" => ->(r) { r["manual_allocation"]["external_pay_period_id"] = "999" },
    "wrong item owner" => ->(r) { r["manual_allocation"]["external_payroll_item_id"] = "999" },
    "wrong REG hours" => ->(r) { r["manual_allocation"]["regular_hours"] = "6" },
    "wrong OT hours" => ->(r) { r["manual_allocation"]["overtime_hours"] = "0" },
    "wrong total hours" => ->(r) { r["manual_allocation"]["total_hours"] = "9" },
    "nonfinite hours" => ->(r) { r["manual_allocation"]["regular_hours"] = "NaN" },
    "wrong method" => ->(r) { r["manual_allocation"]["payment_method"] = "direct_deposit" },
    "wrong reference" => ->(r) { r["manual_allocation"]["payment_reference"] = "WRONG" },
    "wrong effective date" => ->(r) { r["manual_allocation"]["payment_effective_on"] = "2001-01-01" },
    "wrong issuance time" => ->(r) { r["manual_allocation"]["issued_at"] = "2001-01-01T00:00:00Z" },
    "missing payment event" => ->(r) { r["manual_allocation"].delete("issued_payment") },
    "invalid event ID" => ->(r) { r["manual_allocation"]["issued_payment"]["event_id"] = "" },
    "wrong event type" => ->(r) { r["manual_allocation"]["issued_payment"]["event_type"] = "payment_cancelled" },
    "wrong event reference" => ->(r) { r["manual_allocation"]["issued_payment"]["payment_reference"] = "WRONG" },
    "wrong event effective date" => ->(r) { r["manual_allocation"]["issued_payment"]["payment_effective_on"] = "2001-01-01" },
    "wrong event time" => ->(r) { p = r["manual_allocation"]["issued_payment"]; p["occurred_at"] = (Time.iso8601(p["occurred_at"]) + Rational(1, 1_000_000)).iso8601(6) },
    "wrong command" => ->(r) { r["command"]["id"] = SecureRandom.uuid },
    "missing immutable result" => ->(r) { r.delete("command_result") },
    "wrong expected version" => ->(r) { r["command_result"]["expected_version"] = 5 },
    "noninteger expected version" => ->(r) { r["command_result"]["expected_version"] = 0.0 },
    "noninteger result version" => ->(r) { r["command_result"]["result_version"] = 1.0 },
    "invalid event type shape" => ->(r) { r["manual_allocation"]["issued_payment"]["event_id"] = true },
    "wrong result version" => ->(r) { r["command_result"]["result_version"] = 5 },
    "wrong immutable event" => ->(r) { r["command_result"]["manual_allocation"]["issued_payment"]["event_id"] = "999" },
    "wrong immutable installation" => ->(r) { r["command_result"]["integration"]["source_instance_id"] = SecureRandom.uuid },
    "missing command" => ->(r) { r.delete("command") },
    "forged replay flag" => ->(r) { r["command"]["replayed"] = "true" },
    "missing installation descriptor" => ->(r) { r.delete("integration") },
    "changed installation" => ->(r) { r["integration"]["source_instance_id"] = SecureRandom.uuid },
    "changed contract" => ->(r) { r["integration"]["capabilities"] = [] }
  }

  [ false, true ].each do |replayed|
    mutations.each do |name, mutate|
      it "keeps #{replayed ? 'replayed' : 'fresh'} #{name} retryable without adopting paid coverage" do
        allow(client).to receive(:issue_payroll_manual_allocation) do |request|
          receipt = manual_issue_receipt(allocation, request, replayed: replayed)
          mutate.call(receipt)
          # Also reject complete forged work/payment snapshots, not only mixed envelopes.
          if receipt["command_result"] && !name.include?("immutable") && receipt["manual_allocation"] &&
            !name.include?("version")
            receipt["command_result"]["manual_allocation"] = receipt["manual_allocation"].deep_dup
            receipt["command_result"]["manual_allocation"]["issued_payment"]&.delete("reason")
          end
          receipt
        end
        service.sync!(allocation)
        saved = allocation.reload.payment_issue_intent
        expect(allocation).to have_attributes(status: "committed", remote_version: 0)
        expect(saved).to include("command_id" => allocation.issue_command_id,
          "source_instance_id" => source.expected_source_instance_id, "payment_reference" => item.check_number)
        expect(allocation.last_sync_error).to be_present
        service.sync!(allocation)
        expect(allocation.reload.payment_issue_intent).to eq(saved)
        expect(allocation.status).to eq("committed")
      end
    end

    it "accepts a complete #{replayed ? 'replayed' : 'fresh'} issued receipt" do
      allow(client).to receive(:issue_payroll_manual_allocation) do |request|
        manual_issue_receipt(allocation, request, replayed: replayed)
      end
      service.sync!(allocation, raise_on_failure: true)
      expect(allocation.reload).to have_attributes(status: "issued", remote_version: 1,
        payment_issue_intent: {}, last_sync_error: nil)
      service.sync!(allocation, raise_on_failure: true)
      expect(client).to have_received(:issue_payroll_manual_allocation).once
    end
  end

  it "recovers a lost response with the same saved command, original check and exact event time" do
    requests = []
    receipt = nil
    allow(client).to receive(:issue_payroll_manual_allocation) do |request|
      requests << request
      if requests.one?
        receipt = manual_issue_receipt(allocation, request)
        raise TimeTracking::Client::Error, "Synthetic response lost after Source issued"
      end
      receipt.deep_dup.tap { |r| r["command"]["replayed"] = true }
    end
    service.sync!(allocation)
    original_intent = allocation.reload.payment_issue_intent
    item.update!(check_number: "9999")
    item.check_events.create!(event_type: "delivered", user: actor, check_number: "9999",
      effective_on: PayrollBusinessClock.today - 1)
    service.sync!(allocation, raise_on_failure: true)
    expect(requests.last).to eq(requests.first)
    expect(requests.last).to eq(original_intent.except("source_instance_id", "source_contract").symbolize_keys)
    expect(allocation.reload).to have_attributes(status: "issued", remote_version: 1, payment_issue_intent: {})
  end

  it "recovers the original receipt after a verified source adds unrelated capabilities and policy" do
    receipt = nil
    calls = 0
    allow(client).to receive(:issue_payroll_manual_allocation) do |request|
      calls += 1
      if calls == 1
        receipt = manual_issue_receipt(allocation, request)
        raise TimeTracking::Client::Error, "Synthetic lost original response"
      end
      receipt.deep_dup.tap { |r| r["command"]["replayed"] = true }
    end
    service.sync!(allocation)
    saved = allocation.reload.payment_issue_intent
    source.update!(source_capabilities: source.source_capabilities + [ "unrelated_reporting_v1" ],
      source_policy_constraints: { "time_zones" => [ "Pacific/Guam" ] })
    service.sync!(allocation, raise_on_failure: true)
    expect(allocation.reload).to have_attributes(status: "issued", remote_version: 1, payment_issue_intent: {})
    expect(client).to have_received(:issue_payroll_manual_allocation)
      .with(**saved.except("source_instance_id", "source_contract").symbolize_keys).twice
  end

  it "blocks an unpinned installation before creating a remote issuance effect" do
    source.update!(expected_source_instance_id: nil, source_protocol: nil, source_protocol_version: nil, identity_verified_at: nil)
    allow(client).to receive(:issue_payroll_manual_allocation)
    service.sync!(allocation)
    expect(client).not_to have_received(:issue_payroll_manual_allocation)
    expect(allocation.reload).to have_attributes(status: "committed", remote_version: 0, payment_issue_intent: {})
    expect(allocation.last_sync_error).to include("Verify the original source installation")
  end

  it "blocks retry after the configured installation changes, retaining the original intent" do
    allow(client).to receive(:issue_payroll_manual_allocation).and_raise(TimeTracking::Client::Error, "Synthetic lost response")
    service.sync!(allocation)
    saved = allocation.reload.payment_issue_intent
    source.update!(expected_source_instance_id: SecureRandom.uuid)
    service.sync!(allocation)
    expect(client).to have_received(:issue_payroll_manual_allocation).once
    expect(allocation.reload).to have_attributes(status: "committed", remote_version: 0, payment_issue_intent: saved)
    expect(allocation.last_sync_error).to include("original verified source installation")
  end
  context "with a verified generic time producer" do
    let(:source) do
      create(:time_tracking_source, company: company, source_type: "custom", remote_source_identifier: "neutral_time",
        expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
        source_protocol_version: "1.0", identity_verified_at: Time.current,
        source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES)
    end

    it "accepts an immutable compatible producer result with a nonunit advancing version" do
      allow(client).to receive(:issue_payroll_manual_allocation) do |request|
        manual_issue_receipt(allocation, request).tap do |receipt|
          receipt["manual_allocation"]["version"] = 3
          receipt["command_result"]["result_version"] = 3
          receipt["command_result"]["manual_allocation"]["version"] = 3
          event_id = SecureRandom.uuid
          receipt["manual_allocation"]["issued_payment"]["event_id"] = event_id
          receipt["command_result"]["manual_allocation"]["issued_payment"]["event_id"] = event_id
        end
      end
      service.sync!(allocation, raise_on_failure: true)
      expect(allocation.reload).to have_attributes(status: "issued", remote_version: 3, payment_issue_intent: {})
    end
  end

  it "keeps a legacy pending intent without installation evidence unchanged" do
    old_intent = { "allocation_id" => "501", "command_id" => allocation.issue_command_id,
      "expected_version" => 0, "payment_method" => "paper_check", "payment_reference" => item.check_number,
      "payment_effective_on" => PayrollBusinessClock.today.iso8601,
      "occurred_at" => Time.current.iso8601(6), "reason" => "Original saved delivery command" }
    allocation.update!(payment_issue_intent: old_intent)
    allow(client).to receive(:issue_payroll_manual_allocation)
    service.sync!(allocation)
    expect(client).not_to have_received(:issue_payroll_manual_allocation)
    expect(allocation.reload).to have_attributes(status: "committed", remote_version: 0, payment_issue_intent: old_intent)
    expect(allocation.last_sync_error).to include("original verified source installation")
  end

  it "checks the saved installation after the actor client reloads source configuration" do
    allow(TimeTracking::Client).to receive(:for_payroll_actor) do
      source.update!(expected_source_instance_id: SecureRandom.uuid)
      client
    end
    allow(client).to receive(:issue_payroll_manual_allocation)
    service.sync!(allocation)
    expect(client).not_to have_received(:issue_payroll_manual_allocation)
    expect(allocation.reload.status).to eq("committed")
    expect(allocation.payment_issue_intent).to be_present
    expect(allocation.last_sync_error).to include("original verified source installation")
  end

  context "with the shared Source contract fixture" do
    let(:fixture) { JSON.parse(Rails.root.join("spec/fixtures/manual_allocation_issuance_receipt.json").read) }
    let(:period) do
      create(:pay_period, :committed, id: 67, company: company, start_date: "2026-10-01",
        end_date: "2026-10-15", pay_date: "2026-10-15")
    end
    let(:item) { create(:payroll_item, :with_check, id: 91, company: company, employee: employee, pay_period: period) }
    let(:source) do
      integration = fixture.fetch("fresh_response").fetch("integration")
      create(:time_tracking_source, company: company, source_type: "aire_services",
        expected_source_instance_id: integration.fetch("source_instance_id"),
        source_protocol: integration.fetch("protocol"), source_protocol_version: integration.fetch("protocol_version"),
        identity_verified_at: Time.current, source_capabilities: integration.fetch("capabilities"))
    end
    let!(:allocation) do
      TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
        pay_period: period, payroll_item: item, employee: employee, created_by: actor,
        source_user_uuid: "11111111-1111-4111-8111-111111111111", source_time_entry_id: "801",
        source_time_entry_version: 2, original_work_date: "2026-10-01", regular_hours: 8, overtime_hours: 0,
        reconciliation_note: "Exact synthetic fixture work receipt", status: "committed",
        remote_allocation_id: "901", remote_version: 0, issue_command_id: fixture.fetch("request").fetch("command_id"))
    end

    %w[fresh_response replay_response].each do |key|
      it "accepts the unchanged shared #{key} fixture" do
        intent = fixture.fetch("request").merge("allocation_id" => "901",
          "source_instance_id" => source.expected_source_instance_id,
          "source_contract" => { "protocol" => source.source_protocol, "protocol_version" => source.source_protocol_version,
            "capabilities" => source.source_capabilities.sort, "policy_constraints" => source.source_policy_constraints })
        allocation.update!(payment_issue_intent: intent)
        expect(service.send(:issued_allocation_acknowledgement!, fixture.fetch(key), allocation))
          .to eq(fixture.fetch(key).fetch("manual_allocation"))
      end
    end
  end
end
