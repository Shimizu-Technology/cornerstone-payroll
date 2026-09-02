# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollStatusSyncJob, type: :job do
  it "acknowledges the AIRE batch and records the successful delivery" do
    company = create(:company)
    pay_period = create(:pay_period, company: company)
    source = TimeTrackingSource.create!(
      company: company,
      name: "AIRE",
      source_type: "aire_services",
      base_url: "https://aire.example.com",
      shared_secret: "secret"
    )
    import = TimeTrackingImport.create!(
      pay_period: pay_period,
      time_tracking_source: source,
      status: "applied",
      start_date: pay_period.start_date,
      end_date: pay_period.end_date,
      fetch_start_date: pay_period.start_date,
      fetch_end_date: pay_period.end_date,
      source_payload_hash: "a" * 64,
      external_batch_id: "AIRE-PAY-123",
      external_batch_checksum: "a" * 64,
      contract_version: "2.0",
      source_cutoff_at: Time.current,
      raw_payload: {},
      processed_payload: {}
    )
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    expect(client).to receive(:record_payroll_batch_processing_event).with(
      hash_including(
        batch_id: "AIRE-PAY-123",
        event_id: "cornerstone:time-tracking-import:#{import.id}:imported",
        status: "imported",
        external_pay_period_id: pay_period.id.to_s
      )
    )

    described_class.perform_now(import.id, "imported", Time.current.iso8601)

    expect(import.reload).to have_attributes(
      source_processing_status: "imported",
      source_processing_sync_error: nil
    )
    expect(import.source_processing_synced_at).to be_present

    import.record_source_processing_sync!(status: "committed", synced_at: 1.minute.from_now)
    import.record_source_processing_sync!(status: "imported", synced_at: 2.minutes.from_now)
    expect(import.reload.source_processing_status).to eq("committed")

    import.record_source_processing_sync!(status: "payment_failed", synced_at: 3.minutes.from_now)
    import.record_source_processing_sync!(status: "payment_issued", synced_at: 4.minutes.from_now)
    import.record_source_processing_sync!(status: "committed", synced_at: 5.minutes.from_now)
    expect(import.reload.source_processing_status).to eq("payment_issued")
  end
end
