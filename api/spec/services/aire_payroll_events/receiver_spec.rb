# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollEvents::Receiver do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", shared_secret: "integration-secret") }
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 10, 1),
      end_date: Date.new(2026, 10, 15),
      pay_date: Date.new(2026, 10, 25)
    )
  end
  let(:calendar_period) { create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: pay_period) }
  let(:publication) { create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar_period, delivery_status: "delivered") }
  let(:batch_payload) { build_aire_batch_payload }
  let(:event_payload) { build_aire_finalized_event(calendar_period: calendar_period, publication: publication, batch_payload: batch_payload) }

  before do
    allow(AirePayrollEvent).to receive(:dispatch_one!)
  end

  it "authenticates, persists, audits, and queues a finalized event" do
    result = described_class.new(
      payload: event_payload,
      shared_secret: "integration-secret",
      idempotency_key: event_payload.fetch("event_id")
    ).call

    expect(result.created).to be(true)
    expect(result.event).to have_attributes(
      aire_payroll_calendar_period: calendar_period,
      aire_payroll_calendar_publication: publication,
      payroll_batch_id: batch_payload.fetch("batch_id"),
      payroll_batch_checksum: batch_payload.dig("export", "checksum"),
      verification_status: "pending"
    )
    expect(AirePayrollEvent).to have_received(:dispatch_one!).with(result.event.id, now: kind_of(Time))
    expect(AuditLog.find_by!(action: "aire_payroll_event#received").company_id).to eq(company.id)
  end

  it "returns an idempotent replay without another event or queue dispatch" do
    first = described_class.new(
      payload: event_payload,
      shared_secret: "integration-secret",
      idempotency_key: event_payload.fetch("event_id")
    ).call
    second = described_class.new(
      payload: event_payload.deep_dup,
      shared_secret: "integration-secret",
      idempotency_key: event_payload.fetch("event_id")
    ).call

    expect(second.created).to be(false)
    expect(second.event).to eq(first.event)
    expect(AirePayrollEvent.where(event_id: event_payload.fetch("event_id")).count).to eq(1)
    expect(AirePayrollEvent).to have_received(:dispatch_one!).once
  end

  it "rejects a changed replay, bad credentials, and an unknown revision" do
    described_class.new(
      payload: event_payload,
      shared_secret: "integration-secret",
      idempotency_key: event_payload.fetch("event_id")
    ).call
    changed = event_payload.deep_dup
    changed["payroll_batch"]["summary"]["total_hours"] = 9.0

    expect do
      described_class.new(payload: changed, shared_secret: "integration-secret", idempotency_key: changed.fetch("event_id")).call
    end.to raise_error(described_class::ConflictError, /different contents/)
    expect do
      described_class.new(payload: event_payload, shared_secret: "wrong", idempotency_key: event_payload.fetch("event_id")).call
    end.to raise_error(described_class::UnauthorizedError, /Invalid AIRE/)

    unknown = event_payload.deep_dup
    unknown["event_id"] = SecureRandom.uuid
    unknown["payroll_period"]["publication_id"] = SecureRandom.uuid
    expect do
      described_class.new(payload: unknown, shared_secret: "integration-secret", idempotency_key: unknown.fetch("event_id")).call
    end.to raise_error(described_class::ConflictError, /unknown calendar revision/)
  end

  it "rejects events authenticated by a deactivated AIRE source" do
    payload = event_payload.deep_dup
    source.update!(active: false)

    expect do
      described_class.new(
        payload: payload,
        shared_secret: "integration-secret",
        idempotency_key: payload.fetch("event_id")
      ).call
    end.to raise_error(described_class::UnauthorizedError, /Invalid AIRE integration credentials/)
    expect(AirePayrollEvent).not_to exist
  end

  it "allows different AIRE sources to use the same source-local batch ID" do
    first = described_class.new(
      payload: event_payload,
      shared_secret: "integration-secret",
      idempotency_key: event_payload.fetch("event_id")
    ).call
    other_company = create(:company)
    other_source = create(
      :time_tracking_source,
      company: other_company,
      source_type: "aire_services",
      shared_secret: "other-integration-secret"
    )
    other_pay_period = create(
      :pay_period,
      company: other_company,
      start_date: Date.new(2026, 10, 1),
      end_date: Date.new(2026, 10, 15),
      pay_date: Date.new(2026, 10, 25)
    )
    other_calendar = create(
      :aire_payroll_calendar_period,
      company: other_company,
      time_tracking_source: other_source,
      pay_period: other_pay_period
    )
    other_publication = create(
      :aire_payroll_calendar_publication,
      aire_payroll_calendar_period: other_calendar,
      delivery_status: "delivered"
    )
    other_payload = build_aire_finalized_event(
      calendar_period: other_calendar,
      publication: other_publication,
      batch_payload: batch_payload
    )

    second = described_class.new(
      payload: other_payload,
      shared_secret: "other-integration-secret",
      idempotency_key: other_payload.fetch("event_id")
    ).call

    expect(first.event.payroll_batch_id).to eq(second.event.payroll_batch_id)
    expect(first.event.time_tracking_source_id).not_to eq(second.event.time_tracking_source_id)
    expect(AirePayrollEvent.count).to eq(2)
  end

  it "rejects batch metadata that does not match the published period" do
    event_payload["payroll_batch"]["end_date"] = "2026-10-14"

    expect do
      described_class.new(
        payload: event_payload,
        shared_secret: "integration-secret",
        idempotency_key: event_payload.fetch("event_id")
      ).call
    end.to raise_error(described_class::ConflictError, /does not match/)
  end

  it "returns a stable validation error for a null occurred_at" do
    event_payload["occurred_at"] = nil

    expect do
      described_class.new(
        payload: event_payload,
        shared_secret: "integration-secret",
        idempotency_key: event_payload.fetch("event_id")
      ).call
    end.to raise_error(described_class::Error, /occurred_at must be a valid ISO timestamp/)
  end
end
