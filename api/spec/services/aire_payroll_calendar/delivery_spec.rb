# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::Delivery do
  let(:now) { Time.find_zone!("Pacific/Guam").local(2026, 10, 10, 9) }
  let(:calendar_period) { create(:aire_payroll_calendar_period) }
  let(:publication) { create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar_period, next_delivery_attempt_at: now) }
  let(:source_state) do
    publication.payload.slice("start_date", "end_date", "pay_date", "cutoff_at").merge(
      "external_pay_period_id" => calendar_period.external_pay_period_id,
      "schedule_version" => publication.schedule_version,
      "publication_id" => publication.publication_id,
      "status" => "scheduled",
      "cutoff_state" => "upcoming"
    )
  end

  it "delivers the exact version and retains AIRE's returned state" do
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:publish_payroll_calendar_period).and_return(
      "payroll_calendar_period" => source_state,
      "idempotent" => false
    )

    result = described_class.new(
      publication_id: publication.id,
      now: now,
      client_factory: ->(*) { client }
    ).call

    expect(result[:status]).to eq("delivered")
    expect(client).to have_received(:publish_payroll_calendar_period).with(
      external_pay_period_id: calendar_period.external_pay_period_id,
      payload: publication.payload,
      idempotency_key: publication.publication_id
    )
    expect(publication.reload).to have_attributes(
      delivery_status: "delivered",
      delivery_attempts: 1,
      delivered_at: now,
      source_state: source_state
    )
  end

  it "accepts AIRE's UTC cutoff when it represents the published Guam instant" do
    utc_source_state = source_state.merge("cutoff_at" => "2026-10-18T07:00:00Z")
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:publish_payroll_calendar_period).and_return(
      "payroll_calendar_period" => utc_source_state
    )

    result = described_class.new(
      publication_id: publication.id,
      now: now,
      client_factory: ->(*) { client }
    ).call

    expect(result[:status]).to eq("delivered")
    expect(publication.reload).to have_attributes(
      delivery_status: "delivered",
      source_state: utc_source_state
    )
  end

  it "keeps network failures visible and schedules a bounded retry" do
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:publish_payroll_calendar_period)
      .and_raise(TimeTracking::Client::Error.new("AIRE unavailable", response_status: 503))

    result = described_class.new(
      publication_id: publication.id,
      now: now,
      client_factory: ->(*) { client }
    ).call

    expect(result[:status]).to eq("failed")
    expect(publication.reload).to have_attributes(
      delivery_status: "failed",
      delivery_attempts: 1,
      next_delivery_attempt_at: now + 1.minute,
      last_response_status: 503
    )
    expect(publication.last_error).to include("AIRE unavailable")
  end

  it "continues durable recovery attempts at the maximum bounded delay" do
    publication.update!(delivery_attempts: described_class::RETRY_DELAYS.length + 2)
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:publish_payroll_calendar_period)
      .and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    result = described_class.new(
      publication_id: publication.id,
      now: now,
      client_factory: ->(*) { client }
    ).call

    expect(result[:status]).to eq("failed")
    expect(publication.reload.next_delivery_attempt_at).to eq(now + described_class::RETRY_DELAYS.last)
  end

  it "stops automatic delivery attempts once the published cutoff is reached" do
    after_cutoff = Time.find_zone!("Pacific/Guam").local(2026, 10, 18, 17)
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:publish_payroll_calendar_period)
      .and_raise(TimeTracking::Client::Error, "AIRE unavailable")

    result = described_class.new(
      publication_id: publication.id,
      now: after_cutoff,
      client_factory: ->(*) { client }
    ).call

    expect(result[:status]).to eq("failed")
    expect(publication.reload).to have_attributes(
      delivery_status: "failed",
      next_delivery_attempt_at: nil
    )
    expect(AirePayrollCalendarPublication.due_for_delivery(after_cutoff + 1.day)).not_to include(publication)
  end

  it "rejects a successful response for a different revision" do
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:publish_payroll_calendar_period).and_return(
      "payroll_calendar_period" => source_state.merge("schedule_version" => 99)
    )

    result = described_class.new(
      publication_id: publication.id,
      now: now,
      client_factory: ->(*) { client }
    ).call

    expect(result[:status]).to eq("failed")
    expect(publication.reload.delivery_status).to eq("failed")
    expect(publication.last_error).to include("does not match")
  end

  it "does not deliver the same publication twice" do
    publication.update!(delivery_status: "delivered", delivered_at: now, next_delivery_attempt_at: nil)
    client = instance_double(TimeTracking::Client)
    allow(client).to receive(:publish_payroll_calendar_period)

    result = described_class.new(
      publication_id: publication.id,
      now: now,
      client_factory: ->(*) { client }
    ).call

    expect(result[:status]).to eq("delivered")
    expect(client).not_to have_received(:publish_payroll_calendar_period)
  end
end
