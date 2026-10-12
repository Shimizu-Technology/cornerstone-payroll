# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::PaymentAttestationResolutionService do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: RSpec.current_example.metadata[:compatible] ? "custom" : "aire_services",
    remote_source_identifier: RSpec.current_example.metadata[:compatible] ? "compatible_clock" : nil,
    expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
    source_protocol_version: "1.0", identity_verified_at: Time.current,
    source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ described_class::CAPABILITY ]) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:uuid) { SecureRandom.uuid }
  let(:period) { create(:pay_period, :committed, company: company, start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 16)) }
  let(:item) { create(:payroll_item, :with_check, company: company, employee: employee, pay_period: period, hours_worked: 6.1, overtime_hours: 0) }
  let(:delivery) { create(:check_event, payroll_item: item, user: actor, event_type: "delivered", effective_on: PayrollBusinessClock.today) }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:reason) { "Exact reported hours match this existing delivered payroll check" }
  let(:hold) { { "id" => "501", "version" => 3, "source_user_uuid" => uuid, "source_time_entry_id" => "41",
    "source_time_entry_version" => 2, "work_date" => "2026-08-15", "status" => "pending_evidence", "hours" => 6.1,
    "attested_at" => 1.hour.ago.iso8601(6), "resolution_context" => { "available" => true,
      "regular_hours" => "6.10", "overtime_hours" => "0.00", "total_hours" => "6.10", "weekly_context_fingerprint" => "a" * 64 } } }
  subject(:service) { described_class.new(pay_period: period, source: source, actor: actor) }

  before do
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
      employee: employee, source_user_id: "91", source_user_uuid: uuid)
    allow(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: actor).and_return(client)
    allow(TimeTracking::Client).to receive(:for_saved_payroll_actor).with(source, actor: actor,
      binding: { "kind" => "account_link", "actor_id" => actor.id }).and_return(client)
    allow(client).to receive(:payroll_command_binding).and_return("kind" => "account_link", "actor_id" => actor.id)
    allow(client).to receive(:payroll_payment_attestations).and_return("payment_attestations" => [ hold ], "pagination" => { "total_pages" => 1 })
    allow(client).to receive(:resolve_payroll_payment_attestation) { |payload| receipt(payload) }
    delivery unless RSpec.current_example.metadata[:skip_delivery]
  end

  def create_match
    service.create!(attestation_id: "501", source_user_uuid: uuid, payroll_item_id: item.id, expected_version: 3, reason: reason)
  end

  def receipt(payload)
    remote = payload.stringify_keys.slice("source_time_entry_id", "source_time_entry_version", "source_user_uuid", "work_date", "pay_date",
      "external_pay_period_id", "external_payroll_item_id", "payment_method", "payment_reference", "payment_effective_on")
      .merge("id" => "601", "version" => 2, "status" => "issued", "regular_hours" => 6.1, "overtime_hours" => 0,
        "total_hours" => 6.1, "time_category_id" => nil, "issued_at" => payload[:occurred_at], "issued_payment" => {
          "event_id" => "source-event-701", "event_type" => "issued", "occurred_at" => payload[:occurred_at],
          "payment_method" => payload[:payment_method], "payment_reference" => payload[:payment_reference], "payment_effective_on" => payload[:payment_effective_on] })
    evidence = payload.stringify_keys.slice("expected_weekly_context_fingerprint", "payroll_payment_event_type", "payroll_payment_event_id")
    report = hold.except("resolution_context").merge("status" => "resolved", "version" => 5,
      "resolved_at" => Time.current.iso8601(6), "resolved_by_id" => "91", "resolved_manual_allocation_id" => remote["id"],
      "resolved_issued_event_id" => remote.dig("issued_payment", "event_id"), "resolution_evidence" => evidence)
    integration = { "protocol" => source.source_protocol, "protocol_version" => source.source_protocol_version,
      "source_instance_id" => source.expected_source_instance_id, "source_type" => source.connector.source_identifier,
      "capabilities" => source.source_capabilities, "policy_constraints" => source.source_policy_constraints }
    { "command" => { "id" => payload[:command_id], "replayed" => false }, "integration" => integration,
      "payment_attestation" => report, "manual_allocation" => remote, "command_result" => {
        "payment_attestation_id" => 501, "expected_version" => 3, "result_version" => 5, "status" => "resolved",
        "payment_attestation" => report.deep_dup, "manual_allocation_id" => 601,
        "manual_allocation_expected_version" => 0, "manual_allocation_result_version" => 2,
        "manual_allocation" => remote.deep_dup, "integration" => integration.deep_dup }.merge(evidence) }
  end

  it "matches existing exact native evidence without creating any new money or payment event" do
    expect { create_match }.not_to change(CheckEvent, :count)
    allocation = TimeTrackingManualAllocation.last
    expect(allocation).to have_attributes(status: "issued", remote_allocation_id: "601", remote_version: 2)
    expect(allocation.payment_resolution_receipt).to be_present
    expect(service.payment_options(uuid).first).to include(payroll_item_id: item.id, regular_hours_available: 0.0,
      gross_pay: item.gross_pay.to_f, payment_recorded_at: delivery.created_at.iso8601(6))
    expect(client).to have_received(:resolve_payroll_payment_attestation).with(hash_including(
      regular_hours: "6.1", overtime_hours: "0.0", payment_reference: item.check_number,
      payroll_payment_event_type: "delivered_check", payroll_payment_event_id: delivery.id.to_s,
      occurred_at: delivery.created_at.iso8601(6), expected_weekly_context_fingerprint: "a" * 64))
    expect(service.history.first).to include(status: "matched", hours_reserved: true, payment_reference: item.check_number)
  end

  it "saves the reservation before POST and retries the identical command, tuple and actor after a lost response" do
    requests = []
    allow(client).to receive(:resolve_payroll_payment_attestation) do |payload|
      requests << payload
      pending = TimeTrackingManualAllocation.last
      expect(pending.payment_resolution_pending?).to be(true)
      expect(pending.regular_hours).to eq(6.1)
      raise TimeTracking::Client::Error, "Receipt was lost" if requests.size == 1

      receipt(payload).tap { |result| result["command"]["replayed"] = true }
    end
    allocation = create_match
    intent = allocation.reload.payment_resolution_intent
    expect(allocation).to have_attributes(status: "pending_commit", last_sync_error: "Receipt was lost")
    expect(service.history.first[:status]).to eq("pending")
    described_class.new(pay_period: period, source: source, actor: actor).sync!(allocation)
    expect(requests.size).to eq(2)
    expect(requests.first).to eq(requests.last)
    expect(allocation.reload.payment_resolution_intent).to eq(intent)
    expect(allocation.status).to eq("issued")
    expect { create_match }.not_to change(TimeTrackingManualAllocation, :count)
  end

  it "rejects another operator retry without changing its original actor or reservation" do
    allow(client).to receive(:resolve_payroll_payment_attestation).and_raise(TimeTracking::Client::Error, "Lost receipt")
    allocation = create_match
    other = create(:user, company: company, organization: company.organization, role: "admin")
    expect { described_class.new(pay_period: period, source: source, actor: other).sync!(allocation, raise_on_failure: true) }
      .to raise_error(TimeTracking::Client::Error, /original payroll operator/)
    expect(allocation.reload.created_by_id).to eq(actor.id)
    expect(client).to have_received(:resolve_payroll_payment_attestation).once
  end

  it "replays the captured contract after current capabilities change and blocks a changed installation" do
    allow(client).to receive(:resolve_payroll_payment_attestation).and_raise(TimeTracking::Client::Error, "Lost receipt")
    allocation = create_match
    captured = receipt(allocation.payment_resolution_intent.symbolize_keys)
    source.update!(source_capabilities: [ "payment_attestations" ])
    allow(client).to receive(:resolve_payroll_payment_attestation).and_return(captured)
    service.sync!(allocation)
    expect(allocation.reload.status).to eq("issued")
  end

  it "preserves the pending reservation when the original installation changes" do
    allow(client).to receive(:resolve_payroll_payment_attestation).and_raise(TimeTracking::Client::Error, "Lost receipt")
    allocation = create_match
    source.update_columns(expected_source_instance_id: SecureRandom.uuid)
    expect { service.sync!(allocation, raise_on_failure: true) }.to raise_error(TimeTracking::Client::Error, /original verified source/)
  end

  {
    "command identity" => ->(r) { r["command"]["id"] = SecureRandom.uuid },
    "replay flag" => ->(r) { r["command"].delete("replayed") },
    "hold expected version" => ->(r) { r["command_result"]["expected_version"] = 2 },
    "hold nonadvancing version" => ->(r) { r["command_result"]["result_version"] = 3; r["payment_attestation"]["version"] = 3 },
    "allocation nonadvancing version" => ->(r) { r["command_result"]["manual_allocation_expected_version"] = 2 },
    "missing immutable result" => ->(r) { r.delete("command_result") },
    "snapshot mismatch" => ->(r) { r["command_result"]["manual_allocation"]["work_date"] = "2026-08-14" },
    "wrong source install" => ->(r) { r["integration"]["source_instance_id"] = SecureRandom.uuid },
    "wrong capability contract" => ->(r) { r["integration"]["capabilities"] = [ "manual_allocations" ] },
    "wrong native event" => ->(r) { r["command_result"]["payroll_payment_event_id"] = "unrelated-event" },
    "missing weekly fingerprint" => ->(r) { r["command_result"].delete("expected_weekly_context_fingerprint") },
    "wrong report anchor" => ->(r) { r["payment_attestation"]["resolved_manual_allocation_id"] = "other" },
    "wrong issued anchor" => ->(r) { r["payment_attestation"]["resolved_issued_event_id"] = "other" },
    "wrong separate hours" => ->(r) { r["manual_allocation"]["regular_hours"] = 6; r["manual_allocation"]["overtime_hours"] = 0.1 },
    "wrong payment reference" => ->(r) { r["manual_allocation"]["payment_reference"] = "other-check" },
    "wrong payment time" => ->(r) { r["manual_allocation"]["issued_payment"]["occurred_at"] = Time.current.iso8601(6) },
    "malformed hours" => ->(r) { r["manual_allocation"]["regular_hours"] = "NaN" }
  }.each do |name, corrupt|
    it "preserves the original pending intent and reserved hours on rejected #{name}" do
      allow(client).to receive(:resolve_payroll_payment_attestation) { |payload| receipt(payload).tap { |result| corrupt.call(result) } }
      allocation = create_match
      expect(allocation.reload).to have_attributes(status: "pending_commit", remote_allocation_id: nil)
      expect(allocation.payment_resolution_pending?).to be(true)
      expect(allocation.last_sync_error).to be_present
      expect(allocation.regular_hours).to eq(6.1)
      expect(allocation.payment_resolution_receipt).to eq({})
    end
  end

  it "blocks void, renumber, replacement, changed hours and whole-period revision while a receipt is uncertain" do
    allow(client).to receive(:resolve_payroll_payment_attestation).and_raise(TimeTracking::Client::Error, "Lost receipt")
    create_match
    expect(TimeTracking::PaymentCancellationBridge.blocker_for(item)).to include("Reconcile the saved")
    expect(PayrollPaymentMethodEligibility.new(item).call[:eligible]).to be(false)
    expect { item.void!(user: actor, reason: "Review the original payment first") }.to raise_error(ArgumentError, /Reconcile the saved/)
    expect(item.update(check_number: "changed-check")).to be(false)
    item.reload
    expect(item.update(hours_worked: 10)).to be(false)
    item.reload
    expect { item.check_events.create!(user: actor, event_type: "replaced", check_number: item.check_number, reason: reason) }
      .to raise_error(ActiveRecord::RecordInvalid, /Reconcile the saved/)
    expect(period.update(correction_status: "voided")).to be(false)
    expect(PayrollRevisionPaymentPreflight.new(pay_period: period).call[:blockers].join).to include("Reconcile the saved")
  end

  it "blocks corrective paycheck preview and issuance before creating supplemental money while resolution is uncertain" do
    allow(client).to receive(:resolve_payroll_payment_attestation).and_raise(TimeTracking::Client::Error, "Lost receipt")
    create_match
    expect { IssueCorrectivePaycheckService.preview(original_pay_period: period, employee: employee, corrected_inputs: { hours_worked: 7 }) }
      .to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /Reconcile the saved/)
    expect do
      expect { IssueCorrectivePaycheckService.issue!(original_pay_period: period, employee: employee,
        corrected_inputs: { hours_worked: 7 }, pay_date: Date.current, reason: reason, actor: actor) }
        .to raise_error(IssueCorrectivePaycheckService::InvalidStateError, /Reconcile the saved/)
    end.not_to change(PayPeriod, :count)
  end

  it "rejects printed-only evidence, unavailable or changed Source context and REG/OT over-capacity before reserving", skip_delivery: true do
    item.update!(check_printed_at: Time.current)
    expect { create_match }.to raise_error(ArgumentError, /Original payment not verified/)
    delivery = create(:check_event, payroll_item: item, user: actor, event_type: "delivered", effective_on: PayrollBusinessClock.today)
    hold["resolution_context"]["available"] = false
    expect { create_match }.to raise_error(described_class::Error, /historical review/)
    hold["resolution_context"]["available"] = true
    item.update!(hours_worked: 6, overtime_hours: 0.1)
    expect { create_match }.to raise_error(described_class::Error, /separate REG and OT/)
    expect(TimeTrackingManualAllocation.count).to eq(0)
    expect(delivery).to be_persisted
  end

  it "supports a cross-period issued adjustment and server-derived bank proof" do
    second = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 8, 16), end_date: Date.new(2026, 8, 31), pay_date: Date.new(2026, 9, 1))
    bank_item = create(:payroll_item, company: company, employee: employee, pay_period: second, payment_delivery_method: "direct_deposit", check_number: nil, net_pay: 100, gross_pay: 120, hours_worked: 6.1, overtime_hours: 0)
    confirmation = bank_item.create_direct_deposit_payment_confirmation!(user: actor, bank_reference: "SYNTHETIC-BANK", settled_on: PayrollBusinessClock.today)
    allocation = service.create!(attestation_id: "501", source_user_uuid: uuid, payroll_item_id: bank_item.id, expected_version: 3, reason: reason)
    expect(allocation.reload.status).to eq("issued")
    expect(allocation.payment_resolution_intent).to include("external_pay_period_id" => second.id.to_s,
      "payment_reference" => confirmation.bank_reference, "payroll_payment_event_id" => confirmation.id.to_s,
      "payroll_payment_event_type" => "direct_deposit_confirmation")
  end

  it "keeps a cross-period uncertain match discoverable from both original review and issued payment periods" do
    second = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 8, 16), end_date: Date.new(2026, 8, 31), pay_date: Date.new(2026, 9, 1))
    second_item = create(:payroll_item, :with_check, company: company, employee: employee, pay_period: second, hours_worked: 6.1, overtime_hours: 0)
    create(:check_event, payroll_item: second_item, user: actor, event_type: "delivered", effective_on: PayrollBusinessClock.today)
    allow(client).to receive(:resolve_payroll_payment_attestation).and_raise(TimeTracking::Client::Error, "Lost receipt")
    allocation = service.create!(attestation_id: "501", source_user_uuid: uuid, payroll_item_id: second_item.id, expected_version: 3, reason: reason)
    expect(service.history.map { |row| row[:id] }).to eq([ allocation.id ])
    expect(described_class.new(pay_period: second, source: source, actor: actor).history.map { |row| row[:id] }).to eq([ allocation.id ])
    expect(period.update(notes: "Review context retained")).to be(true)
    expect(service.history.map { |row| row[:id] }).to eq([ allocation.id ])
    expect(second.update(correction_status: "voided")).to be(false)
  end

  it "supports a verified compatible producer with the identical explicit capability and immutable receipt", compatible: true do
    allocation = create_match
    expect(allocation.reload.status).to eq("issued")
    expect(allocation.payment_resolution_intent.dig("source_contract", "source_identifier")).to eq("compatible_clock")
  end

  it "keeps immutable original command, capacity, operator and receipt after acknowledgement" do
    allocation = create_match
    expect(allocation.update(payment_resolution_intent: {})).to be(false)
    allocation.reload
    expect(allocation.update(regular_hours: 5)).to be(false)
    allocation.reload
    expect(allocation.update(payment_resolution_receipt: {})).to be(false)
  end

  it "preserves durable reservation and reports a controlled error for a malformed receipt body" do
    allow(client).to receive(:resolve_payroll_payment_attestation).and_return([ "invalid" ])
    allocation = create_match
    expect(allocation.reload.payment_resolution_pending?).to be(true)
    expect(allocation.last_sync_error).to include("did not prove")
  end

  it "normalizes UUID case for new and existing exact matches and scopes Source reads to this work period" do
    allocation = service.create!(attestation_id: "501", source_user_uuid: uuid.upcase, payroll_item_id: item.id, expected_version: 3, reason: reason)
    expect(allocation.source_user_uuid).to eq(uuid)
    expect(client).to have_received(:payroll_payment_attestations).with(source_user_uuid: uuid, page: 1,
      start_date: period.start_date.iso8601, end_date: period.end_date.iso8601)
    expect { service.create!(attestation_id: "501", source_user_uuid: uuid.upcase, payroll_item_id: item.id, expected_version: 3, reason: reason) }
      .not_to change(TimeTrackingManualAllocation, :count)
  end

  it "records local acknowledgement failure without losing the saved command and reconciles its exact replay" do
    fail_ack = true
    allow(TimeTrackingManualAllocation).to receive(:create!).and_wrap_original do |original, **attributes|
      record = original.call(**attributes)
      allow(record).to receive(:update!).and_wrap_original do |update, **changes|
        if changes.key?(:payment_resolution_receipt) && fail_ack
          fail_ack = false
          record.assign_attributes(changes)
          record.errors.add(:base, "Synthetic local acknowledgement write failed")
          raise ActiveRecord::RecordInvalid, record
        end
        update.call(**changes)
      end
      record
    end
    allocation = create_match
    original_intent = allocation.reload.payment_resolution_intent
    expect(allocation.status).to eq("pending_commit")
    expect(allocation.remote_allocation_id).to be_nil
    expect(allocation.last_sync_error).to include("Synthetic local acknowledgement write failed")
    expect(allocation.payment_resolution_receipt).to eq({})
    service.sync!(allocation)
    expect(allocation.reload.status).to eq("issued")
    expect(allocation.payment_resolution_intent).to eq(original_intent)
    requests = []
    expect(client).to have_received(:resolve_payroll_payment_attestation).twice { |payload| requests << payload }
    expect(requests.first).to eq(requests.last)
  end

  it "requires explicit capability for AIRE and compatible producers, never legacy fallback" do
    source.update!(source_capabilities: [])
    expect { create_match }.to raise_error(described_class::Error, /capability/)
    expect(TimeTrackingManualAllocation.count).to eq(0)
  end
end
