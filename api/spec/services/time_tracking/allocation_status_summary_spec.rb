# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::AllocationStatusSummary do
  let(:company) { create(:company) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }
  let(:employee) { create(:employee, company: company) }
  let(:payroll_item) { create(:payroll_item, pay_period: pay_period, employee: employee) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:import) do
    create(
      :time_tracking_import,
      :finalized_aire_batch,
      pay_period: pay_period,
      time_tracking_source: source,
      status: "applied",
      processed_payload: {
        "exclusions" => [ { "source_time_entry_id" => "held-1", "held_total_hours" => "1.50" } ]
      }
    )
  end

  it "separates exact linked hours by their latest payment evidence" do
    paid = allocation("paid", 5)
    pending = allocation("pending", 3)
    voided = allocation("voided", 2)
    allocation("missing", 1)

    acknowledgement(paid, "committed", 4.hours.ago)
    acknowledgement(paid, "payment_issued", 1.hour.ago, delivered_at: 30.minutes.ago)
    acknowledgement(pending, "payment_prepared", 2.hours.ago)
    acknowledgement(voided, "payment_issued", 3.hours.ago)
    acknowledgement(voided, "payment_voided", 1.hour.ago, last_error: "AIRE unavailable")

    result = described_class.call(import.reload)

    expect(result).to include(line_count: 4, total_hours: 11.to_d, regular_hours: 11.to_d, overtime_hours: 0.to_d)
    expect(result[:paid]).to include(line_count: 1, total_hours: 5.to_d)
    expect(result[:payment_pending]).to include(line_count: 1, total_hours: 3.to_d)
    expect(result[:in_payroll]).to include(line_count: 0, total_hours: 0.to_d)
    expect(result[:needs_attention]).to include(line_count: 2, total_hours: 3.to_d)
    expect(result[:held]).to eq(entry_count: 1, total_hours: 1.5.to_d)
    expect(result[:synchronization]).to include(pending_event_count: 4, failed_event_count: 1)
    expect(result.dig(:synchronization, :last_confirmed_at)).to be_within(1.second).of(30.minutes.ago)
  end

  it "includes the status summary in the saved AIRE record for a pay period" do
    linked = allocation("linked", 8)
    acknowledgement(linked, "committed", 1.hour.ago)

    record = PayPeriodTimeTrackingSummary.call(pay_period).fetch(:linked_aire_records).sole

    expect(record.fetch(:payable_line_status)).to include(line_count: 1, total_hours: 8.to_d)
    expect(record.dig(:payable_line_status, :in_payroll)).to include(line_count: 1, total_hours: 8.to_d)
    expect(record.dig(:payable_line_status, :held)).to eq(entry_count: 1, total_hours: 1.5.to_d)
  end

  def allocation(key, hours)
    TimeTrackingEntryAllocation.create!(
      company: company,
      time_tracking_source: source,
      time_tracking_import: import,
      pay_period: pay_period,
      payroll_item: payroll_item,
      employee: employee,
      source_user_id: "source-user-1",
      source_time_entry_id: "entry-#{key}",
      line_key: "line-#{key}",
      source_kind: "current",
      original_work_date: pay_period.start_date,
      total_hours: hours,
      regular_hours: hours,
      overtime_hours: 0
    )
  end

  def acknowledgement(allocation, status, occurred_at, delivered_at: nil, last_error: nil)
    record = AirePayrollEntryAcknowledgement.record_from_rows!(
      rows: [ allocation ],
      source_event_key: "spec:#{allocation.line_key}:#{status}",
      status: status,
      occurred_at: occurred_at,
      payroll_item_id: payroll_item.id
    )
    record.update!(delivered_at: delivered_at, last_error: last_error)
    record
  end
end
