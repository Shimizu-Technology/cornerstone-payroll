# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ManualAllocationService do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:period) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2026, 8, 1),
                                    end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 16))
  end
  let(:item) do
    create(:payroll_item, :with_check, company: company, pay_period: period, employee: employee,
                                       hours_worked: 6.1, overtime_hours: 0)
  end
  let(:uuid) { SecureRandom.uuid }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:service) { described_class.new(pay_period: period, source: source, actor: actor) }

  before do
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
                                        employee: employee, source_user_id: "91", source_user_uuid: uuid)
    allow(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: actor).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(
      "employees" => [ { "source_user_uuid" => uuid,
                         "adjustments" => [ { "source_time_entry_id" => "41",
                                              "source_time_entry_version" => 2,
                                              "original_work_date" => "2026-08-15",
                                              "regular_hours" => 6.1, "overtime_hours" => 0 } ] } ]
    )
    allow(client).to receive(:commit_payroll_manual_allocation).and_return(
      "manual_allocation" => { "id" => "501", "version" => 0 }
    )
  end

  def create_link
    service.create!(payroll_item_id: item.id, source_time_entry_id: "41", source_time_entry_version: 2,
                    source_user_uuid: uuid, regular_hours: "6.10", overtime_hours: "0.00",
                    original_work_date: "2026-08-15", note: "These issued check hours are the old AIRE carryover")
  end

  %w[pending_commit committed issued].each do |status|
    it "blocks disabled-source #{status} sync without remote writes and records a durable typed error" do
      allocation = TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
        pay_period: period, payroll_item: item, employee: employee, created_by: actor,
        source_user_uuid: uuid, source_time_entry_id: "41", source_time_entry_version: 2,
        original_work_date: "2026-08-15", regular_hours: "6.10", overtime_hours: 0,
        reconciliation_note: "This original-source allocation needs exact payment evidence", status: status,
        remote_allocation_id: status == "pending_commit" ? nil : "501", remote_version: status == "pending_commit" ? nil : 1)
      before_state = allocation.attributes.except("last_sync_error", "updated_at")
      source.update!(active: false)
      expect { service.sync!(allocation, raise_on_failure: true) }.to raise_error(TimeTracking::Client::Error) { |error|
        expect(error.response_status).to eq(422)
        expect(error.message).to include("original AIRE source is inactive")
      }
      expect(allocation.reload.attributes.except("last_sync_error", "updated_at")).to eq(before_state)
      expect(allocation.last_sync_error).to include("original AIRE source is inactive")
      expect(TimeTracking::Client).not_to have_received(:for_payroll_actor)
      expect(item.reload.check_events).to be_empty
    end
  end

  it "blocks mismatched source context without using either source's actor client" do
    allocation = TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
      pay_period: period, payroll_item: item, employee: employee, created_by: actor,
      source_user_uuid: uuid, source_time_entry_id: "41", source_time_entry_version: 2,
      original_work_date: "2026-08-15", regular_hours: "6.10", overtime_hours: 0,
      reconciliation_note: "This pending allocation retains its original source identity")
    other_source = create(:time_tracking_source, source_type: "aire_services")
    other_service = described_class.new(pay_period: period, source: other_source, actor: actor)
    expect { other_service.sync!(allocation, raise_on_failure: true) }.to raise_error(TimeTracking::Client::Error, /does not match/)
    expect(allocation.reload).to have_attributes(status: "pending_commit", remote_allocation_id: nil, remote_version: nil)
    expect(TimeTracking::Client).not_to have_received(:for_payroll_actor)
  end

  it "links exact AIRE hours to a committed paycheck and retains a retryable local record" do
    allocation = create_link

    expect(allocation).to have_attributes(status: "committed", remote_allocation_id: "501")
    expect(client).to have_received(:commit_payroll_manual_allocation).with(
      hash_including(entry_id: "41", source_user_uuid: uuid, regular_hours: "6.1",
                     external_pay_period_id: period.id.to_s, external_payroll_item_id: item.id.to_s)
    )
    expect { create_link }.to raise_error(described_class::Error, /already linked to this payroll item/)
  end

  it "preserves legitimate partial source hours covered by different payroll items" do
    item.update!(hours_worked: 3.05)
    second_period = create(:pay_period, :committed, company: company,
      start_date: Date.new(2026, 8, 16), end_date: Date.new(2026, 8, 31), pay_date: Date.new(2026, 9, 1))
    second_item = create(:payroll_item, :with_check, company: company, pay_period: second_period,
      employee: employee, hours_worked: 3.05, overtime_hours: 0)
    parameters = { source_time_entry_id: "41", source_time_entry_version: 2, source_user_uuid: uuid,
      regular_hours: "3.05", overtime_hours: "0.00", original_work_date: "2026-08-15",
      note: "Each issued check covers only half of this exact source entry" }
    first = service.create!(payroll_item_id: item.id, **parameters)
    second = described_class.new(pay_period: second_period, source: source, actor: actor)
      .create!(payroll_item_id: second_item.id, **parameters)

    expect(first.status).to eq("committed")
    expect(second.status).to eq("committed")
    expect(TimeTrackingManualAllocation.where(source_time_entry_id: "41").sum(:regular_hours)).to eq(6.1)
    expect(first.payroll_item_id).not_to eq(second.payroll_item_id)
  end

  it "does not mark the hours paid until a delivered check event exists" do
    allocation = create_link
    allow(client).to receive(:issue_payroll_manual_allocation).and_return(
      "manual_allocation" => { "id" => "501", "version" => 1 }
    )
    service.sync!(allocation)
    expect(allocation.reload.status).to eq("committed")

    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    service.sync!(allocation.reload)

    expect(allocation.reload.status).to eq("issued")
    expect(client).to have_received(:issue_payroll_manual_allocation).with(
      hash_including(allocation_id: "501", payment_reference: item.check_number,
                     payment_effective_on: PayrollBusinessClock.today.iso8601)
    )
  end

  it "links direct-deposit hours but waits for bank confirmation before marking them paid" do
    item.update!(payment_delivery_method: "direct_deposit", check_number: nil, net_pay: 100)
    allocation = create_link
    expect(allocation.reload.status).to eq("committed")
    allow(client).to receive(:issue_payroll_manual_allocation).and_return(
      "manual_allocation" => { "id" => "501", "version" => 1 }
    )

    service.sync!(allocation)
    expect(allocation.reload.status).to eq("committed")
    expect(client).not_to have_received(:issue_payroll_manual_allocation)

    item.create_direct_deposit_payment_confirmation!(
      user: actor, settled_on: PayrollBusinessClock.today, bank_reference: "BANK-TEST-123"
    )
    service.sync!(allocation.reload)

    expect(allocation.reload.status).to eq("issued")
    expect(client).to have_received(:issue_payroll_manual_allocation).with(
      hash_including(payment_method: "direct_deposit", payment_reference: "BANK-TEST-123",
                     payment_effective_on: PayrollBusinessClock.today.iso8601)
    )
  end

  it "links a concurrent deposit change but withholds paid status until bank confirmation" do
    item
    allow(client).to receive(:issue_payroll_manual_allocation)
    allow_any_instance_of(PayrollItem).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      original.receiver.update_columns(payment_delivery_method: "direct_deposit", check_number: nil)
      original.call(*args, &block)
    end

    allocation = create_link
    expect(item.reload.effective_payment_delivery_method).to eq("direct_deposit")
    expect(allocation.reload.status).to eq("committed")
    expect(TimeTrackingManualAllocation.count).to eq(1)
    expect(client).not_to have_received(:issue_payroll_manual_allocation)
  end

  it "releases committed AIRE hours when the paycheck is voided before delivery" do
    allocation = create_link
    item.update_columns(voided: true, voided_at: Time.current)
    allow(client).to receive(:issue_payroll_manual_allocation)
    allow(client).to receive(:void_payroll_manual_allocation).and_return(
      "manual_allocation" => { "id" => "501", "version" => 1 }
    )

    service.sync!(allocation.reload)

    expect(allocation.reload.status).to eq("voided")
    expect(client).not_to have_received(:issue_payroll_manual_allocation)
    expect(client).to have_received(:void_payroll_manual_allocation).with(
      hash_including(allocation_id: "501", expected_version: 0)
    )
  end

  it "keeps delivered hours paid when a paycheck is later voided pending nonpayment evidence" do
    allocation = create_link
    allow(client).to receive(:issue_payroll_manual_allocation).and_return(
      "manual_allocation" => { "id" => "501", "version" => 1 }
    )
    allow(client).to receive(:void_payroll_manual_allocation)
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    service.sync!(allocation.reload)
    item.update_columns(voided: true, voided_at: Time.current)

    service.sync!(allocation.reload)

    expect(allocation.reload.status).to eq("issued")
    expect(allocation.last_sync_error).to match(/Verify bank nonpayment or replacement/)
    expect(client).not_to have_received(:void_payroll_manual_allocation)
  end

  it "refuses to link a different AIRE person to the paycheck" do
    expect do
      service.create!(payroll_item_id: item.id, source_time_entry_id: "41", source_time_entry_version: 2,
                      source_user_uuid: SecureRandom.uuid, regular_hours: "6.10", overtime_hours: "0.00",
                      original_work_date: "2026-08-15", note: "These issued check hours are the old AIRE carryover")
    end.to raise_error(described_class::Error, /Map this AIRE person/)
  end

  it "rejects source hours that exceed the committed paycheck" do
    item.update!(hours_worked: 5)

    expect { create_link }.to raise_error(described_class::Error, /exceed the regular or overtime hours/)
    expect(TimeTrackingManualAllocation.count).to eq(0)
  end

  it "retains a pending link and visible error when AIRE is temporarily unavailable" do
    allow(client).to receive(:commit_payroll_manual_allocation)
      .and_raise(TimeTracking::Client::Error.new("AIRE temporarily unavailable", response_status: 503))

    allocation = create_link

    expect(allocation.reload).to have_attributes(status: "pending_commit", remote_allocation_id: nil)
    expect(allocation.last_sync_error).to include("AIRE temporarily unavailable")
  end

  it "keeps a malformed AIRE commitment acknowledgement retryable" do
    allow(client).to receive(:commit_payroll_manual_allocation).and_return("manual_allocation" => { "id" => "501" })

    allocation = create_link

    expect(allocation.reload.status).to eq("pending_commit")
    expect(allocation.last_sync_error).to include("invalid manual allocation acknowledgement")
  end

  it "keeps malformed or mismatched AIRE payment acknowledgements retryable" do
    allocation = create_link
    create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                         effective_on: PayrollBusinessClock.today)
    allow(client).to receive(:issue_payroll_manual_allocation).and_return(
      "manual_allocation" => { "id" => "999", "version" => 1 }
    )

    service.sync!(allocation.reload)

    expect(allocation.reload.status).to eq("committed")
    expect(allocation.last_sync_error).to include("invalid manual allocation acknowledgement")
  end
end
