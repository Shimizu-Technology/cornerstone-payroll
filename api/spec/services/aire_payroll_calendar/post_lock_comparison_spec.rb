# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::PostLockComparison do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:pay_period) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2026, 10, 1),
                                    end_date: Date.new(2026, 10, 15), pay_date: Date.new(2026, 10, 25))
  end
  let(:calendar_period) do
    create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: pay_period)
  end
  let(:publication) do
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar_period,
                                             delivery_status: "delivered")
  end
  let(:payload) { build_aire_batch_payload }
  let(:client) { instance_double(TimeTracking::Client, payroll_batch: payload) }
  let(:service) { described_class.new(pay_period: pay_period, source: source, client: client) }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:uuid) { SecureRandom.uuid }

  def verified_event
    event_payload = build_aire_finalized_event(calendar_period: calendar_period, publication: publication,
                                               batch_payload: payload)
    AirePayrollEvent.create!(
      aire_payroll_calendar_period: calendar_period,
      aire_payroll_calendar_publication: publication,
      time_tracking_source: source,
      event_id: event_payload.fetch("event_id"), event_type: event_payload.fetch("event_type"),
      occurred_at: Time.iso8601(event_payload.fetch("occurred_at")), payload: event_payload,
      payload_checksum: TimeTracking::CanonicalPayload.checksum(event_payload),
      payroll_batch_id: payload.fetch("batch_id"),
      payroll_batch_checksum: payload.dig("export", "checksum"),
      verification_status: "verified", verified_at: Time.current
    )
  end

  it "keeps confirmed payments, unconfirmed links, still-owed hours, and held hours separate" do
    payload.fetch("employees").first["source_user_uuid"] = uuid
    payload.fetch("exclusions").first["source_user_uuid"] = uuid
    payload.fetch("export")["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    verified_event
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
                                        employee: employee, source_user_id: "42", source_user_uuid: uuid)
    item = create(:payroll_item, :with_check, company: company, pay_period: pay_period, employee: employee,
                                            hours_worked: 11)
    base = {
      company: company, time_tracking_source: source, pay_period: pay_period,
      payroll_item: item, employee: employee, created_by: actor, source_user_uuid: uuid,
      source_time_entry_version: 0, original_work_date: Date.new(2026, 10, 5),
      overtime_hours: 0, reconciliation_note: "Exact AIRE source line reviewed"
    }
    TimeTrackingManualAllocation.create!(**base, source_time_entry_id: "101", regular_hours: 2, status: "issued")
    TimeTrackingManualAllocation.create!(**base, source_time_entry_id: "303", regular_hours: 1, status: "committed")

    result = service.call

    expect(result.dig(:summary, "paid")).to include(regular_hours: 2.0, entry_count: 1)
    expect(result.dig(:summary, "awaiting_payment")).to include(regular_hours: 1.0, entry_count: 1)
    expect(result.dig(:summary, "owed")).to include(regular_hours: 8.0, entry_count: 1)
    expect(result.dig(:summary, "held")).to include(regular_hours: 4.0, entry_count: 1)
    expect(result.dig(:summary, :needs_attention)).to be(true)
    expect(result.fetch(:rows).map { |row| row.fetch(:status) }).to contain_exactly(
      "paid", "awaiting_payment", "owed", "held"
    )
  end

  it "does not show an unverified final batch as reconciled" do
    expect { service.call }.to raise_error(described_class::Error, /verified final cutoff/)
    expect(client).not_to have_received(:payroll_batch)
  end

  it "includes confirmed payment for a carryover source entry linked in a later pay period" do
    person = payload.fetch("employees").first
    person["source_user_uuid"] = uuid
    line = person.fetch("adjustments").first
    line["source_kind"] = "carryover"
    line["original_work_date"] = "2026-09-26"
    line["original_week_start"] = "2026-09-20"
    payload.fetch("summary")["current_count"] = 0
    payload.fetch("summary")["carryover_count"] = 1
    payload.fetch("export")["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    verified_event
    later_period = create(:pay_period, :committed, company: company,
                                                 start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31),
                                                 pay_date: Date.new(2026, 11, 15))
    item = create(:payroll_item, :with_check, company: company, pay_period: later_period,
                                            employee: employee, hours_worked: 2)
    TimeTrackingManualAllocation.create!(
      company: company, time_tracking_source: source, pay_period: later_period,
      payroll_item: item, employee: employee, created_by: actor, source_user_uuid: uuid,
      source_time_entry_id: "101", source_time_entry_version: 0,
      original_work_date: Date.new(2026, 9, 26), regular_hours: 2, overtime_hours: 0,
      reconciliation_note: "Later check paid this exact carryover line", status: "issued"
    )

    result = service.call

    expect(result.dig(:summary, "paid", :regular_hours)).to eq(2.0)
    expect(result.fetch(:rows).find { |row| row[:payroll_item_id] == item.id }).to include(status: "paid", source_time_entry_id: "101")
  end

  it "flags a payroll link whose source identity no longer matches the final AIRE line" do
    payload.fetch("employees").first["source_user_uuid"] = uuid
    payload.fetch("export")["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    verified_event
    item = create(:payroll_item, :with_check, company: company, pay_period: pay_period, employee: employee, hours_worked: 2)
    TimeTrackingManualAllocation.create!(
      company: company, time_tracking_source: source, pay_period: pay_period,
      payroll_item: item, employee: employee, created_by: actor, source_user_uuid: SecureRandom.uuid,
      source_time_entry_id: "101", source_time_entry_version: 0,
      original_work_date: Date.new(2026, 10, 5), regular_hours: 2, overtime_hours: 0,
      reconciliation_note: "Legacy identity requires a source review", status: "issued"
    )

    result = service.call

    expect(result.dig(:summary, "mismatch", :regular_hours)).to eq(2.0)
    expect(result.fetch(:rows).find { |row| row[:payroll_item_id] == item.id }.fetch(:reason)).to include("identity")
  end

  it "does not classify a held entry as paid when the linked employee identity differs" do
    payload.fetch("exclusions").first["source_user_uuid"] = uuid
    payload.fetch("export")["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    verified_event
    item = create(:payroll_item, :with_check, company: company, pay_period: pay_period, employee: employee, hours_worked: 2)
    TimeTrackingManualAllocation.create!(
      company: company, time_tracking_source: source, pay_period: pay_period,
      payroll_item: item, employee: employee, created_by: actor, source_user_uuid: SecureRandom.uuid,
      source_time_entry_id: "202", source_time_entry_version: 0,
      original_work_date: Date.new(2026, 10, 6), regular_hours: 2, overtime_hours: 0,
      reconciliation_note: "Held AIRE entry linked to wrong identity", status: "issued"
    )

    result = service.call

    expect(result.fetch(:rows).find { |row| row[:payroll_item_id] == item.id }.fetch(:status)).to eq("mismatch")
    expect(result.dig(:summary, "paid", :regular_hours)).to eq(0.0)
  end

  it "does not count an unrelated different-payroll payment merely because its work date is in range" do
    verified_event
    other_period = create(:pay_period, :committed, company: company,
                                                 start_date: Date.new(2026, 9, 16), end_date: Date.new(2026, 9, 30),
                                                 pay_date: Date.new(2026, 10, 15))
    item = create(:payroll_item, :with_check, company: company, pay_period: other_period,
                                            employee: employee, hours_worked: 3)
    TimeTrackingManualAllocation.create!(
      company: company, time_tracking_source: source, pay_period: other_period,
      payroll_item: item, employee: employee, created_by: actor, source_user_uuid: uuid,
      source_time_entry_id: "999", source_time_entry_version: 0,
      original_work_date: Date.new(2026, 10, 5), regular_hours: 3, overtime_hours: 0,
      reconciliation_note: "Unrelated earlier payroll payment", status: "issued"
    )

    result = service.call

    expect(result.dig(:summary, "paid", :regular_hours)).to eq(0.0)
    expect(result.fetch(:rows).map { |row| row[:source_time_entry_id] }).not_to include("999")
  end

  it "calls out numeric-only legacy links without treating them as permanent employee matches" do
    payload.fetch("employees").first["source_user_uuid"] = uuid
    payload.fetch("export")["checksum"] = TimeTracking::CanonicalPayload.checksum(payload.except("export"))
    verified_event
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
                                        employee: employee, source_user_id: "42", source_user_uuid: nil)

    result = service.call

    expect(result.dig(:summary, :needs_verification_count)).to be_positive
    expect(result.fetch(:rows).select { |row| row[:source_kind] != "held" }.first.fetch(:mapping_status))
      .to eq("needs_verification")
  end

  it "shows bank settlement evidence for paid direct-deposit allocations" do
    verified_event
    item = create(:payroll_item, company: company, pay_period: pay_period, employee: employee,
                                 hours_worked: 2, gross_pay: 30, net_pay: 25,
                                 payment_delivery_method: "direct_deposit")
    DirectDepositPaymentConfirmation.create!(payroll_item: item, user: actor,
                                             settled_on: PayrollBusinessClock.today,
                                             bank_reference: "BANK-POSTLOCK-123")
    TimeTrackingManualAllocation.create!(
      company: company, time_tracking_source: source, pay_period: pay_period,
      payroll_item: item, employee: employee, created_by: actor,
      source_user_uuid: uuid, source_time_entry_id: "501", source_time_entry_version: 0,
      original_work_date: Date.new(2026, 10, 5), regular_hours: 2, overtime_hours: 0,
      reconciliation_note: "Exact AIRE source line reviewed", status: "issued"
    )

    paid = service.call.fetch(:rows).find { |row| row[:source_time_entry_id] == "501" }

    expect(paid).to include(status: "paid", payment_method: "direct_deposit",
                            payment_reference: "BANK-POSTLOCK-123")
  end

  it "refuses a final batch whose immutable checksum changed" do
    verified_event
    payload.fetch("summary")["total_hours"] = 9

    expect { service.call }.to raise_error(described_class::Error, /checksum/)
  end
end
