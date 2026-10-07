# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Manual allocation instrument cancellation" do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) { create(:payroll_item, :with_check, company: company, employee: employee, pay_period: period, payment_delivery_method: "paper_check", check_number: "8000", hours_worked: 5, overtime_hours: 1) }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "aire_services",
      expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "1.0", identity_verified_at: Time.current,
      source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ "payment_cancellation_v1" ])
  end
  let!(:allocation) do
    TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
      pay_period: period, payroll_item: item, employee: employee, created_by: actor,
      source_user_uuid: SecureRandom.uuid, source_time_entry_id: "41", source_time_entry_version: 2,
      original_work_date: period.start_date, regular_hours: 5, overtime_hours: 1,
      reconciliation_note: "Synthetic exact frozen source hours", status: "committed",
      remote_allocation_id: "501", remote_version: 0)
  end
  let(:service) { TimeTracking::ManualAllocationService.new(pay_period: period, source: source, actor: actor) }
  let(:client) { instance_double(TimeTracking::Client) }

  before do
    allow(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: actor).and_return(client)
    allow(client).to receive(:issue_payroll_manual_allocation).and_return("manual_allocation" => { "id" => "501", "version" => 1, "status" => "issued" })
    allow(client).to receive(:cancel_payroll_manual_allocation_payment) { |**request| cancellation_ack(version: 2, request: request) }
  end

  def cancellation_ack(version:, request:)
    { "command" => { "id" => request.fetch(:command_id), "replayed" => false }, "manual_allocation" => {
      "id" => "501", "version" => version, "status" => "committed",
      "source_time_entry_id" => allocation.source_time_entry_id,
      "source_time_entry_version" => allocation.source_time_entry_version,
      "source_user_uuid" => allocation.source_user_uuid, "work_date" => allocation.original_work_date.iso8601,
      "regular_hours" => allocation.regular_hours.to_s("F"), "overtime_hours" => allocation.overtime_hours.to_s("F"),
      "external_pay_period_id" => period.id.to_s, "external_payroll_item_id" => item.id.to_s,
      "cancelled_payment" => request.slice(:payment_method, :payment_reference, :payment_effective_on,
        :cancellation_evidence_reference, :reason, :occurred_at).stringify_keys.merge(
          "event_id" => "source-cancellation-event", "event_type" => "payment_cancelled")
    } }
  end

  def retire
    PayrollPaymentMethodService.new(payroll_item: item, actor: actor, method: "direct_deposit",
      reason: "Recovered original check before payment", confirm_not_paid: true,
      retire_existing_check: true, confirm_check_cancelled: true,
      cancellation_evidence_reference: "Synthetic recovered instrument 42", expected_check_number: "8000").call
  end

  it "cancels issued hours to committed and rotates the issue command only after the ack is saved" do
    item.check_events.create!(event_type: "delivered", check_number: "8000", user: actor)
    service.sync!(allocation, raise_on_failure: true)
    original_command = allocation.reload.issue_command_id
    identities = allocation.attributes.slice("source_user_uuid", "source_time_entry_id", "source_time_entry_version", "regular_hours", "overtime_hours", "original_work_date")
    retire
    cancellation = allocation.reload.payment_cancellation_intent
    service.sync!(allocation, raise_on_failure: true)
    expect(allocation.reload).to have_attributes(status: "committed", remote_version: 2, payment_cancellation_intent: {}, payment_issue_intent: {})
    expect(allocation.issue_command_id).not_to eq(original_command)
    expect(allocation.attributes.slice(*identities.keys)).to eq(identities)
    expect(allocation.payment_cancellation_receipts.sole).to include("command_id" => cancellation["command_id"], "payment_reference" => "8000", "remote_version" => 2)
    expect(client).to have_received(:cancel_payroll_manual_allocation_payment).with(hash_including(expected_version: 1,
      payment_reference: "8000", cancellation_evidence_reference: "Synthetic recovered instrument 42"))
  end

  it "replays a remote issue whose local persistence failed before cancelling its exact acknowledged version" do
    item.check_events.create!(event_type: "delivered", check_number: "8000", user: actor)
    allow(service).to receive(:persist_remote_transition!).and_raise(ActiveRecord::ActiveRecordError, "Synthetic lost local ack")
    expect { service.sync!(allocation, raise_on_failure: true) }.to raise_error(ActiveRecord::ActiveRecordError)
    original_intent = allocation.reload.payment_issue_intent
    expect(original_intent).to include("payment_reference" => "8000", "expected_version" => 0)
    expect(allocation.status).to eq("committed")
    retire
    service.sync!(allocation, raise_on_failure: true)
    expect(client).to have_received(:issue_payroll_manual_allocation).with(**original_intent.symbolize_keys).twice
    expect(client).to have_received(:cancel_payroll_manual_allocation_payment).with(hash_including(expected_version: 1))
    expect(allocation.reload.status).to eq("committed")
  end

  it "replays the frozen cancellation command after a remote cancellation succeeds but its local ack fails" do
    item.check_events.create!(event_type: "delivered", check_number: "8000", user: actor)
    service.sync!(allocation, raise_on_failure: true)
    old_issue_command = allocation.reload.issue_command_id
    retire
    calls = 0
    allow(service).to receive(:persist_cancellation_acknowledgement!).and_wrap_original do |original, *arguments|
      calls += 1
      raise ActiveRecord::ActiveRecordError, "Synthetic lost cancellation ack" if calls == 1
      original.call(*arguments)
    end
    expect { service.sync!(allocation, raise_on_failure: true) }.to raise_error(ActiveRecord::ActiveRecordError)
    saved = allocation.reload.payment_cancellation_intent
    expect(saved).to include("expected_version" => 1)
    expect(allocation.issue_command_id).to eq(old_issue_command)
    service.sync!(allocation, raise_on_failure: true)
    expected = saved.except("check_event_id").symbolize_keys.merge(allocation_id: "501")
    expect(client).to have_received(:cancel_payroll_manual_allocation_payment).with(**expected).twice
    expect(allocation.reload.payment_cancellation_receipts.length).to eq(1)
    expect(allocation.issue_command_id).not_to eq(old_issue_command)
  end

  it "tombstones a committed prepared allocation and holds replacement issuance until cancellation is acknowledged" do
    item.mark_package_prepared!(user: actor)
    old_issue_command = allocation.issue_command_id
    retire
    DirectDepositPaymentConfirmation.create!(payroll_item: item, user: actor,
      settled_on: PayrollBusinessClock.today, bank_reference: "Synthetic replacement transfer")
    allow(client).to receive(:cancel_payroll_manual_allocation_payment).and_raise(TimeTracking::Client::Error, "Synthetic unavailable producer")
    expect { service.sync!(allocation, raise_on_failure: true) }.to raise_error(TimeTracking::Client::Error)
    expect(client).not_to have_received(:issue_payroll_manual_allocation)
    expect(allocation.reload.issue_command_id).to eq(old_issue_command)
    expect(allocation.payment_cancellation_intent).to be_present
    allow(client).to receive(:cancel_payroll_manual_allocation_payment) { |**request| cancellation_ack(version: 1, request: request) }
    allow(client).to receive(:issue_payroll_manual_allocation).and_return("manual_allocation" => { "id" => "501", "version" => 2, "status" => "issued" })
    service.sync!(allocation, raise_on_failure: true)
    expect(client).to have_received(:issue_payroll_manual_allocation).with(hash_including(payment_method: "direct_deposit", payment_reference: "Synthetic replacement transfer", expected_version: 1))
    expect(allocation.reload.status).to eq("issued")
    expect(allocation.issue_command_id).not_to eq(old_issue_command)
  end

  it "tombstones every pending allocation after its commit acknowledgement, not only local issued rows" do
    allocation.update!(status: "pending_commit", remote_allocation_id: nil, remote_version: nil)
    allow(client).to receive(:commit_payroll_manual_allocation).and_return("manual_allocation" => { "id" => "501", "version" => 0 })
    allow(client).to receive(:cancel_payroll_manual_allocation_payment) { |**request| cancellation_ack(version: 1, request: request) }
    item.mark_package_prepared!(user: actor)
    retire
    service.sync!(allocation, raise_on_failure: true)
    expect(allocation.reload).to have_attributes(status: "committed", remote_version: 1)
    expect(allocation.payment_cancellation_receipts.length).to eq(1)
    expect(client).to have_received(:commit_payroll_manual_allocation)
    expect(client).to have_received(:cancel_payroll_manual_allocation_payment)
    expect(client).not_to have_received(:issue_payroll_manual_allocation)
  end

  it "holds the cancellation intent for a wrong command, owner, tuple, hours or nonadvancing version" do
    item.mark_package_prepared!(user: actor)
    retire
    original_issue_command = allocation.reload.issue_command_id
    mutators = [ ->(ack) { ack.delete("command") }, ->(ack) { ack["command"] = "invalid" },
      ->(ack) { ack["command"]["id"] = SecureRandom.uuid },
      ->(ack) { ack["manual_allocation"]["source_user_uuid"] = SecureRandom.uuid },
      ->(ack) { ack["manual_allocation"]["regular_hours"] = "6.00" },
      ->(ack) { ack["manual_allocation"]["external_payroll_item_id"] = "other-item" },
      ->(ack) { ack["manual_allocation"]["version"] = 0 },
      ->(ack) { ack["manual_allocation"]["cancelled_payment"]["payment_reference"] = "other-check" },
      ->(ack) { payment = ack["manual_allocation"]["cancelled_payment"]; payment["occurred_at"] = (Time.iso8601(payment["occurred_at"]) + Rational(1, 1_000_000)).iso8601(6) },
      ->(ack) { ack["manual_allocation"]["cancelled_payment"]["cancellation_evidence_reference"] = "other-evidence" } ]
    mutators.each do |mutate|
      allow(client).to receive(:cancel_payroll_manual_allocation_payment) do |**request|
        ack = cancellation_ack(version: 1, request: request)
        mutate.call(ack)
        ack
      end
      expect { service.sync!(allocation, raise_on_failure: true) }.to raise_error(TimeTracking::Client::Error, /committed payroll obligation/)
      expect(allocation.reload.payment_cancellation_intent).to be_present
      expect(allocation.issue_command_id).to eq(original_issue_command)
      expect(allocation.payment_cancellation_receipts).to be_empty
    end
    # The generic protocol promises monotonic versions, not a fixed step size.
    allow(client).to receive(:cancel_payroll_manual_allocation_payment) { |**request| cancellation_ack(version: 3, request: request) }
    service.sync!(allocation, raise_on_failure: true)
    expect(allocation.reload.remote_version).to eq(3)
    expect(allocation.payment_cancellation_intent).to be_empty
  end

  it "does not clear cancellation intent or rotate issuance after a malformed source acknowledgement" do
    item.mark_package_prepared!(user: actor)
    retire
    command = allocation.reload.issue_command_id
    allow(client).to receive(:cancel_payroll_manual_allocation_payment).and_return("manual_allocation" => { "id" => "foreign", "version" => 1, "status" => "committed" })
    expect { service.sync!(allocation, raise_on_failure: true) }.to raise_error(TimeTracking::Client::Error, /invalid manual allocation acknowledgement/)
    expect(allocation.reload.payment_cancellation_intent).to be_present
    expect(allocation.issue_command_id).to eq(command)
    expect(allocation.payment_cancellation_receipts).to be_empty
  end
end
