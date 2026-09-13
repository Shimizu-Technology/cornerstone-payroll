# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollEvents::Verifier do
  let(:now) { Time.find_zone!("Pacific/Guam").local(2026, 10, 18, 17, 5) }
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:pay_period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 15), pay_date: Date.new(2026, 10, 25))
  end
  let(:calendar_period) { create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: pay_period) }
  let(:publication) { create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar_period, delivery_status: "delivered") }
  let(:batch_payload) { build_aire_batch_payload }
  let(:event_payload) { build_aire_finalized_event(calendar_period: calendar_period, publication: publication, batch_payload: batch_payload) }
  let(:event) do
    create_event(event_payload)
  end

  def create_event(payload)
    AirePayrollEvent.create!(
      aire_payroll_calendar_period: calendar_period,
      aire_payroll_calendar_publication: publication,
      time_tracking_source: source,
      event_id: payload.fetch("event_id"),
      event_type: payload.fetch("event_type"),
      occurred_at: Time.iso8601(payload.fetch("occurred_at")),
      payload: payload,
      payload_checksum: TimeTracking::CanonicalPayload.checksum(payload),
      payroll_batch_id: payload.dig("payroll_batch", "id"),
      payroll_batch_checksum: payload.dig("payroll_batch", "checksum"),
      next_verification_attempt_at: now
    )
  end

  it "fetches and verifies the authoritative immutable Batch v2" do
    client = instance_double(TimeTracking::Client, payroll_batch: batch_payload)

    result = described_class.new(event_id: event.id, now: now, client_factory: ->(*) { client }).call

    expect(result[:status]).to eq("verified")
    expect(event.reload).to have_attributes(
      verification_status: "verified",
      verification_attempts: 1,
      verified_at: now,
      last_error: nil
    )
    expect(event.verified_batch_summary).to include(
      "batch_id" => batch_payload.fetch("batch_id"),
      "checksum" => batch_payload.dig("export", "checksum")
    )
    expect(source.reload.last_synced_at).to eq(now)
  end

  it "accepts equivalent cutoff timestamp representations from the event and batch endpoint" do
    equivalent_event_payload = event_payload.deep_dup
    equivalent_event_payload["payroll_batch"]["cutoff_at"] = Time.iso8601(
      batch_payload.fetch("cutoff_at")
    ).utc.iso8601
    equivalent_event = create_event(equivalent_event_payload)
    client = instance_double(TimeTracking::Client, payroll_batch: batch_payload)

    result = described_class.new(
      event_id: equivalent_event.id,
      now: now,
      client_factory: ->(*) { client }
    ).call

    expect(result[:status]).to eq("verified")
    expect(equivalent_event.reload).to be_verified
  end

  it "keeps an outage retryable" do
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:payroll_batch).and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    result = described_class.new(event_id: event.id, now: now, client_factory: ->(*) { client }).call

    expect(result[:status]).to eq("failed")
    expect(event.reload).to have_attributes(
      verification_status: "failed",
      verification_attempts: 1,
      next_verification_attempt_at: now + 1.minute
    )
  end

  it "continues durable recovery attempts at the maximum bounded delay" do
    event.update!(verification_attempts: described_class::RETRY_DELAYS.length + 2)
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:payroll_batch).and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    result = described_class.new(event_id: event.id, now: now, client_factory: ->(*) { client }).call

    expect(result[:status]).to eq("failed")
    expect(event.reload.next_verification_attempt_at).to eq(now + described_class::RETRY_DELAYS.last)
  end

  it "rejects a permanently mismatched immutable batch without retrying it" do
    mismatched = batch_payload.deep_dup
    mismatched["summary"]["total_hours"] = 9.0
    mismatched["summary"]["regular_hours"] = 9.0
    mismatched["employees"][0]["total_hours"] = 9.0
    mismatched["employees"][0]["regular_hours"] = 9.0
    mismatched["employees"][0]["adjustments"][0]["total_hours"] = 9.0
    mismatched["employees"][0]["adjustments"][0]["regular_hours"] = 9.0
    mismatched["export"]["checksum"] = TimeTracking::CanonicalPayload.checksum(mismatched.except("export"))
    client = instance_double(TimeTracking::Client, payroll_batch: mismatched)

    result = described_class.new(event_id: event.id, now: now, client_factory: ->(*) { client }).call

    expect(result[:status]).to eq("rejected")
    expect(event.reload.verification_status).to eq("rejected")
    expect(event.next_verification_attempt_at).to be_nil
    expect(event.last_error).to include("does not match the finalized event")
    expect(AirePayrollEvent.due_for_verification(now + 1.day)).not_to include(event)
  end
end
