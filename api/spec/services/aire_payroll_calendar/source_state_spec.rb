# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::SourceState do
  let(:source) { create(:time_tracking_source, source_type: "aire_services") }
  let(:calendar) { create(:aire_payroll_calendar_period, company: source.company, time_tracking_source: source) }
  let!(:publication) do
    create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar, delivery_status: "delivered",
      source_state: { "next_scheduled_cutoff_at" => "2026-11-07T17:00:00+10:00" })
  end
  let(:client) { instance_double(TimeTracking::Client) }
  let(:service) { described_class.new(source, client_factory: ->(*) { client }) }
  let(:cutoff) { "2026-11-22T17:00:00+10:00" }
  let(:remote) do
    { "external_pay_period_id" => calendar.external_pay_period_id, "publication_id" => publication.publication_id,
      "schedule_version" => publication.schedule_version, "next_scheduled_cutoff_at" => cutoff }
  end

  before { allow(client).to receive(:payroll_calendar_period).and_return("payroll_calendar_period" => remote) }

  def present
    AirePayrollCalendar::Presenter.call(calendar.pay_period)
  end

  it "refreshes an old page from source-wide state without modifying its delivery evidence" do
    original = publication.attributes.slice("payload", "payload_checksum", "source_state")
    expect(service.refresh).to include("status" => "available", "next_scheduled_cutoff_at" => cutoff)
    expect(present).to include(next_scheduled_cutoff_at: cutoff, next_scheduled_cutoff_status: "available")
    expect(publication.reload.attributes.slice(*original.keys)).to eq(original)
    expect(present[:next_scheduled_cutoff_refreshed_at]).to be_present
  end

  it "distinguishes an authoritative null from an unavailable response without a local fallback" do
    remote["next_scheduled_cutoff_at"] = nil
    expect(service.refresh).to include("status" => "available", "next_scheduled_cutoff_at" => nil)
    expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "available")
    allow(client).to receive(:payroll_calendar_period).and_raise(TimeTracking::Client::Error, "Offline")
    expect(service.refresh).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
    expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "unavailable")
  end

  it "does not interpret a missing field as authoritative null" do
    remote.delete("next_scheduled_cutoff_at")
    expect(service.refresh).to include("status" => "unavailable")
  end

  it "rejects a source response for a different publication" do
    remote["publication_id"] = SecureRandom.uuid
    expect(service.refresh).to include("status" => "unavailable")
  end

  it "rejects malformed cutoff values" do
    remote["next_scheduled_cutoff_at"] = false
    expect(service.refresh).to include("status" => "unavailable")
  end

  it "uses the latest delivered period while updating every older page on the source" do
    newer = create(:aire_payroll_calendar_period, company: source.company, time_tracking_source: source)
    second = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: newer, delivery_status: "delivered", delivered_at: Time.current)
    remote.merge!("external_pay_period_id" => newer.external_pay_period_id, "publication_id" => second.publication_id,
      "schedule_version" => second.schedule_version)
    service.refresh
    expect(client).to have_received(:payroll_calendar_period).with(external_pay_period_id: newer.external_pay_period_id)
    expect(present[:next_scheduled_cutoff_at]).to eq(cutoff)
    expect(publication.reload.source_state["next_scheduled_cutoff_at"]).not_to eq(cutoff)
  end

  context "after a finalization callback" do
    before do
      allow(AirePayrollEvent).to receive(:dispatch_one!)
      source.update!(payroll_calendar_source_state: { "status" => "available", "next_scheduled_cutoff_at" => publication.payload["cutoff_at"] })
      batch = build_aire_batch_payload(cutoff_at: publication.payload["cutoff_at"])
      payload = build_aire_finalized_event(calendar_period: calendar, publication: publication, batch_payload: batch)
      AirePayrollEvents::Receiver.new(payload: payload, shared_secret: source.shared_secret, idempotency_key: payload["event_id"]).call
    end

    it "immediately clears the finalized cutoff even when the follow-up GET fails" do
      expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "unavailable")
      allow(client).to receive(:payroll_calendar_period).and_raise(TimeTracking::Client::Error, "Offline")
      service.refresh
      expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "unavailable")
      expect(AirePayrollCalendarSourceRefreshJob).to have_been_enqueued.with(source.id)
    end

    it "clears the only scheduled cutoff to authoritative null" do
      remote["next_scheduled_cutoff_at"] = nil
      service.refresh
      expect(present).to include(next_scheduled_cutoff_at: nil, next_scheduled_cutoff_status: "available")
    end

    it "advances to the source's scheduled successor" do
      service.refresh
      expect(present).to include(next_scheduled_cutoff_at: cutoff, next_scheduled_cutoff_status: "available")
    end

    it "does not resurrect a finalized cutoff from a stale remote observation" do
      remote["next_scheduled_cutoff_at"] = publication.payload["cutoff_at"]
      expect(service.refresh).to include("status" => "unavailable", "next_scheduled_cutoff_at" => nil)
    end
  end
end
