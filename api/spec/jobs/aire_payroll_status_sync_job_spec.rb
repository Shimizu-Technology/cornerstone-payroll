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

    acknowledgement = AirePayrollAcknowledgement.record!(
      time_tracking_import: import,
      status: "imported",
      occurred_at: Time.current
    )

    described_class.perform_now(acknowledgement.id)

    expect(import.reload).to have_attributes(
      source_processing_status: "imported",
      source_processing_sync_error: nil
    )
    expect(import.source_processing_synced_at).to be_present
    expect(acknowledgement.reload.delivered_at).to be_present

    event_time = Time.current
    import.record_source_processing_sync!(status: "committed", synced_at: 1.minute.from_now, occurred_at: event_time)
    import.record_source_processing_sync!(status: "imported", synced_at: 2.minutes.from_now, occurred_at: event_time - 1.minute)
    expect(import.reload.source_processing_status).to eq("committed")

    import.record_source_processing_sync!(status: "payment_failed", synced_at: 3.minutes.from_now, occurred_at: event_time + 1.minute)
    import.record_source_processing_sync!(status: "payment_issued", synced_at: 4.minutes.from_now, occurred_at: event_time + 2.minutes)
    import.record_source_processing_sync!(status: "committed", synced_at: 5.minutes.from_now, occurred_at: event_time + 3.minutes)
    expect(import.reload.source_processing_status).to eq("payment_issued")
  end

  it "does not let a stale failed delivery overwrite a newer successful status" do
    company = create(:company)
    pay_period = create(:pay_period, company: company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    import = create(
      :time_tracking_import,
      :finalized_aire_batch,
      pay_period: pay_period,
      time_tracking_source: source,
      status: "applied",
      source_processing_status: "committed",
      source_processing_synced_at: Time.current,
      source_processing_sync_error: nil
    )
    acknowledgement = AirePayrollAcknowledgement.record!(
      time_tracking_import: import,
      status: "imported",
      occurred_at: 1.minute.ago
    )
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:record_payroll_batch_processing_event).and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    expect do
      described_class.new.perform(acknowledgement.id)
    end.to raise_error(TimeTracking::Client::Error, "AIRE unavailable")

    expect(import.reload).to have_attributes(
      source_processing_status: "committed",
      source_processing_sync_error: nil
    )
    expect(acknowledgement.reload.last_error).to eq("AIRE unavailable")
  end

  it "does not surface a delayed payment failure after a newer payment event succeeded" do
    company = create(:company)
    pay_period = create(:pay_period, company: company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    newer_event_time = Time.current
    import = create(
      :time_tracking_import,
      :finalized_aire_batch,
      pay_period: pay_period,
      time_tracking_source: source,
      status: "applied",
      source_processing_status: "payment_issued",
      source_processing_synced_at: Time.current,
      source_processing_event_occurred_at: newer_event_time,
      source_processing_sync_error: nil
    )
    acknowledgement = AirePayrollAcknowledgement.record!(
      time_tracking_import: import,
      status: "payment_failed",
      occurred_at: newer_event_time - 1.minute
    )
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:record_payroll_batch_processing_event).and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    expect do
      described_class.new.perform(acknowledgement.id)
    end.to raise_error(TimeTracking::Client::Error, "AIRE unavailable")

    expect(import.reload).to have_attributes(
      source_processing_status: "payment_issued",
      source_processing_event_occurred_at: be_within(0.000001).of(newer_event_time),
      source_processing_sync_error: nil
    )
    expect(acknowledgement.reload.last_error).to eq("AIRE unavailable")
  end

  it "keeps an unsuperseded payment delivery failure visible for retry" do
    company = create(:company)
    pay_period = create(:pay_period, company: company)
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    previous_event_time = 2.minutes.ago
    import = create(
      :time_tracking_import,
      :finalized_aire_batch,
      pay_period: pay_period,
      time_tracking_source: source,
      status: "applied",
      source_processing_status: "committed",
      source_processing_synced_at: 1.minute.ago,
      source_processing_event_occurred_at: previous_event_time,
      source_processing_sync_error: nil
    )
    acknowledgement = AirePayrollAcknowledgement.record!(
      time_tracking_import: import,
      status: "payment_failed",
      occurred_at: Time.current
    )
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:record_payroll_batch_processing_event).and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    expect do
      described_class.new.perform(acknowledgement.id)
    end.to raise_error(TimeTracking::Client::Error, "AIRE unavailable")

    expect(import.reload).to have_attributes(
      source_processing_status: "committed",
      source_processing_sync_error: "AIRE unavailable"
    )
    expect(acknowledgement.reload.last_error).to eq("AIRE unavailable")
  end
end
