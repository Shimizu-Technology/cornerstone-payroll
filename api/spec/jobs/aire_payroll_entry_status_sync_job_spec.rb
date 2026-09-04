# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollEntryStatusSyncJob, type: :job do
  it "sends the exact AIRE entry identity and marks the outbox record delivered" do
    company = create(:company)
    pay_period = create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 8, 16),
      end_date: Date.new(2026, 8, 31),
      pay_date: Date.new(2026, 9, 4)
    )
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    import = create(
      :time_tracking_import,
      :finalized_aire_batch,
      pay_period: pay_period,
      time_tracking_source: source,
      status: "applied"
    )
    employee = create(:employee, company: company)
    item = create(:payroll_item, pay_period: pay_period, employee: employee)
    source_user_uuid = SecureRandom.uuid
    allocation = TimeTrackingEntryAllocation.create!(
      company: company,
      time_tracking_source: source,
      time_tracking_import: import,
      pay_period: pay_period,
      payroll_item: item,
      employee: employee,
      source_user_id: "aire-user-1",
      source_user_uuid: source_user_uuid,
      source_time_entry_id: "1508",
      line_key: "flight:3000",
      source_kind: "current",
      original_work_date: Date.new(2026, 8, 20),
      total_hours: 8,
      regular_hours: 8,
      overtime_hours: 0
    )
    acknowledgement = AirePayrollEntryAcknowledgement.record_from_rows!(
      rows: [ allocation ],
      source_event_key: "spec:entry:1508:issued",
      status: "payment_issued",
      occurred_at: Time.zone.parse("2026-09-04 12:00:00"),
      payroll_item_id: item.id,
      payment_method: "paper_check",
      payment_reference: "5001"
    )
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)

    expect(client).to receive(:record_payroll_entry_processing_event).with(
      batch_id: import.external_batch_id,
      event_id: acknowledgement.event_id,
      status: "payment_issued",
      occurred_at: acknowledgement.occurred_at.iso8601,
      external_pay_period_id: pay_period.id.to_s,
      external_payroll_item_id: item.id.to_s,
      source_time_entry_id: "1508",
      source_user_uuid: source_user_uuid,
      payment_method: "paper_check",
      payment_reference: "5001",
      metadata: {
        company_id: company.id,
        pay_period_start: "2026-08-16",
        pay_period_end: "2026-08-31",
        pay_date: "2026-09-04"
      }
    ).and_return(true)

    described_class.perform_now(acknowledgement.id)

    expect(acknowledgement.reload.delivered_at).to be_present
    expect(acknowledgement.last_error).to be_nil
  end
end
