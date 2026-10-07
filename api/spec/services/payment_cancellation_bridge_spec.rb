# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Connected payment cancellation" do
  let(:company) { create(:company, next_check_number: 8001) }
  let(:employee) { create(:employee, company: company) }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) { create(:payroll_item, :with_check, pay_period: period, employee: employee, company: company, check_number: "8000", payment_delivery_method: "paper_check") }
  let(:source) do
    create(:time_tracking_source, company: company, source_type: "aire_services",
      expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "1.0", identity_verified_at: Time.current,
      source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ "payment_cancellation_v1" ])
  end
  let(:import) { create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source, status: "applied") }
  let!(:line) do
    TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source,
      time_tracking_import: import, pay_period: period, payroll_item: item, employee: employee,
      source_user_id: "91", source_user_uuid: SecureRandom.uuid, source_time_entry_id: "41",
      line_key: "flight:41", source_kind: "current", original_work_date: period.start_date,
      total_hours: 6, regular_hours: 5, overtime_hours: 1)
  end

  def retire
    PayrollPaymentMethodService.new(payroll_item: item, actor: actor, method: "direct_deposit",
      reason: "Original instrument recovered and cancelled", confirm_not_paid: true,
      retire_existing_check: true, confirm_check_cancelled: true,
      cancellation_evidence_reference: "Bank stop payment synthetic 42", expected_check_number: "8000").call
  end

  it "requires an explicitly pinned capability rather than legacy AIRE defaults" do
    item.mark_package_prepared!(user: actor)
    original_event_count = item.check_events.count
    source.update!(source_capabilities: [])
    expect(PayrollPaymentMethodEligibility.new(item).call).to include(eligible: false)
    expect { retire }.to raise_error(PayrollPaymentMethodService::Error, /verify payment cancellation/)
    expect(item.reload.check_number).to eq("8000")
    expect(item.check_events.count).to eq(original_event_count)
  end

  it "rejects retirement without the original exact receipt before native mutation" do
    expect { retire }.to raise_error(PayrollPaymentMethodService::Error, /receipt is missing/)
    expect(item.reload).to have_attributes(check_number: "8000", payment_delivery_method: "paper_check")
  end

  it "keeps payroll and frozen hours while queuing cancellation after the original receipt and replacement after cancellation" do
    item.mark_package_prepared!(user: actor)
    prepared = AirePayrollEntryAcknowledgement.find_by!(status: "payment_prepared")
    item.check_events.create!(event_type: "delivered", check_number: "8000", user: actor)
    issued = AirePayrollEntryAcknowledgement.find_by!(status: "payment_issued")
    money = item.attributes.slice("gross_pay", "net_pay", "withholding_tax", "social_security_tax", "medicare_tax")
    retire
    cancelled = AirePayrollEntryAcknowledgement.find_by!(status: "payment_cancelled")
    expect(TimeTracking::AllocationStatusSummary.call(import.reload)[:in_payroll]).to include(total_hours: 6.to_d)
    expect(cancelled.delivery_dependencies).to eq([ issued.id ])
    expect(issued.delivery_dependencies).to eq([ prepared.id ])
    expect(cancelled.cancellation_metadata).to include("cancelled_payment_event_id" => issued.event_id,
      "cancellation_evidence_reference" => "Bank stop payment synthetic 42", "payroll_obligation_retained" => true)
    expect(cancelled).to have_attributes(payment_reference: "8000", regular_hours: 5, overtime_hours: 1,
      source_user_uuid: line.source_user_uuid, payment_effective_on: issued.payment_effective_on)
    expect(item.reload).not_to be_voided
    expect(item.attributes.slice(*money.keys)).to eq(money)
    confirmation = DirectDepositPaymentConfirmation.create!(payroll_item: item, user: actor,
      settled_on: PayrollBusinessClock.today, bank_reference: "Replacement transfer synthetic")
    replacement = AirePayrollEntryAcknowledgement.where(status: "payment_issued", payment_method: "direct_deposit").sole
    expect(replacement.delivery_dependencies).to eq([ cancelled.id ])
    expect(confirmation).to be_persisted
    expect { AirePayrollEntryStatusSyncJob.new.perform(replacement.id) }
      .to raise_error(TimeTracking::Client::Error, /earlier source payment receipt/)
    expect(replacement.reload.delivered_at).to be_nil
    prepared.mark_delivered!(at: Time.current)
    issued.mark_delivered!(at: Time.current)
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    expect(client).to receive(:record_payroll_entry_processing_event).with(hash_including(status: "payment_cancelled",
      payment_reference: "8000", source_user_uuid: line.source_user_uuid,
      metadata: hash_including(cancelled_payment_event_id: issued.event_id,
        cancellation_evidence_reference: "Bank stop payment synthetic 42", payroll_obligation_retained: true)))
    AirePayrollEntryStatusSyncJob.new.perform(cancelled.id)
    expect(cancelled.reload.delivered_at).to be_present
    expect(client).to receive(:record_payroll_entry_processing_event).with(hash_including(status: "payment_issued", payment_method: "direct_deposit"))
    AirePayrollEntryStatusSyncJob.new.perform(replacement.id)
    expect(replacement.reload.delivered_at).to be_present
  end

  it "rejects connected legacy allocations with missing employee incarnation without altering payroll" do
    item.mark_package_prepared!(user: actor)
    original_event_count = item.check_events.count
    TimeTrackingEntryAllocation.where(id: line.id).update_all(source_user_uuid: nil)
    expect { retire }.to raise_error(PayrollPaymentMethodService::Error, /employee identity/)
    expect(item.reload.check_number).to eq("8000")
    expect(item.check_events.count).to eq(original_event_count)
  end

  it "preserves the simple unprepared switch for a verified four-capability producer" do
    source.update!(source_capabilities: %w[time_summary_v1 finalized_batch_v2 payroll_calendar_v2 exact_line_receipts_v2])
    hours = line.attributes.slice("source_user_uuid", "total_hours", "regular_hours", "overtime_hours")
    expect(PayrollPaymentMethodEligibility.new(item).call).to include(eligible: true, mode: "simple")
    PayrollPaymentMethodService.new(payroll_item: item, actor: actor, method: "direct_deposit",
      reason: "No instrument was prepared or issued", confirm_not_paid: true, expected_check_number: "8000").call
    expect(item.reload).to have_attributes(payment_delivery_method: "direct_deposit", check_number: nil, voided: false)
    expect(line.reload.attributes.slice(*hours.keys)).to eq(hours)
    expect(item.aire_payroll_entry_acknowledgements).to be_empty
  end

  it "allows a same-method future default update after bank confirmation without changing the instrument" do
    item.update!(payment_delivery_method: "direct_deposit", check_number: nil)
    confirmation = DirectDepositPaymentConfirmation.create!(payroll_item: item, user: actor,
      settled_on: PayrollBusinessClock.today, bank_reference: "Synthetic existing bank transfer")
    PayrollPaymentMethodService.new(payroll_item: item, actor: actor, method: "direct_deposit",
      reason: "Update the future employee preference", confirm_not_paid: false, update_employee_default: true).call
    expect(employee.reload.payment_delivery_method).to eq("direct_deposit")
    expect(confirmation.reload.bank_reference).to eq("Synthetic existing bank transfer")
    expect(item.reload.check_number).to be_nil
  end

  it "rejects a cancellation aimed at a different original instrument" do
    item.mark_package_prepared!(user: actor)
    prepared = item.aire_payroll_entry_acknowledgements.find_by!(status: "payment_prepared")
    count = AirePayrollEntryAcknowledgement.count
    expect { AirePayrollEntryAcknowledgement.record_from_rows!(rows: [ line ],
      source_event_key: "synthetic-forged-instrument", status: "payment_cancelled", occurred_at: Time.current,
      payroll_item_id: item.id, payment_method: "paper_check", payment_reference: "other-check",
      payment_effective_on: prepared.payment_effective_on, cancellation_metadata: {
        "cancelled_payment_event_id" => prepared.event_id, "cancellation_evidence_reference" => "Synthetic recovered check",
        "payroll_obligation_retained" => true }) }.to raise_error(ActiveRecord::RecordInvalid, /original exact payment receipt/)
    expect(AirePayrollEntryAcknowledgement.count).to eq(count)
  end

  it "rejects a 201-character evidence reference before retiring a check or updating the future default" do
    item.mark_package_prepared!(user: actor)
    state = item.attributes
    default = employee.payment_delivery_method
    receipt_count = AirePayrollEntryAcknowledgement.count
    event_count = item.check_events.count
    number = company.reload.next_check_number
    expect { PayrollPaymentMethodService.new(payroll_item: item, actor: actor, method: "direct_deposit",
      reason: "Recovered original instrument before payment", confirm_not_paid: true,
      retire_existing_check: true, confirm_check_cancelled: true, update_employee_default: true,
      cancellation_evidence_reference: "a" * 201, expected_check_number: "8000").call }
      .to raise_error(PayrollPaymentMethodService::Error, /200 characters/)
    expect(item.reload.attributes).to eq(state)
    expect(employee.reload.payment_delivery_method).to eq(default)
    expect(AirePayrollEntryAcknowledgement.count).to eq(receipt_count)
    expect(item.check_events.count).to eq(event_count)
    expect(company.reload.next_check_number).to eq(number)
  end

  it "freshly rejects an existing bank confirmation even when the caller cached its absence" do
    line # keep connected ownership in the test too
    item.update!(payment_delivery_method: "direct_deposit", check_number: nil)
    expect(item.direct_deposit_payment_confirmation).to be_nil
    DirectDepositPaymentConfirmation.create!(payroll_item: item, user: actor,
      settled_on: PayrollBusinessClock.today, bank_reference: "Synthetic transfer completed")
    expect { PayrollPaymentMethodService.new(payroll_item: item, actor: actor, method: "paper_check",
      reason: "No payment falsely asserted", confirm_not_paid: true).call }
      .to raise_error(PayrollPaymentMethodService::Error, /bank payment has already been confirmed/)
    expect(item.reload.check_number).to be_nil
    expect(company.reload.next_check_number).to eq(8001)
  end
end
